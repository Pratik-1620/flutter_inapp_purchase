import StoreKit
import Flutter

typealias FailureCallBack = (String) -> Void

enum ProductLoadError {
    case inValidProductIds /// This case happens whenever productId passed was mismatch with original productIds
    case notLoadedProductIds([String]) /// This case happen while some product not load and return that product id
    case error(String) /// This case return error message
}

enum PurchaseError {
    case pending  /// This case return if transaction goes in pending state
    case userCancelled /// This case happen if user cancel purchase while purchasing product
    case unverified /// This case happen if transaction can't verify
    case unknown /// This case happen if can't identify error
    case error(String) /// This case return error message
}

enum RestoreError {
    case expired /// This case happen if user try restore and purchased was expired
    case neverPurchased /// This case happen if user never purchased any product
    case error(String) /// This case return error message
}

@available(iOS 15.0, *)
final class IAPManager {
    static let shared = IAPManager()
    private var products: [Product] = []
    var isProductLoaded: Bool = false
    var channel: FlutterMethodChannel!
    
    private init() {
        self.doInitSetup()
    }
    
    private func doInitSetup() {
        /// Initialise transaction update for listen any transaction update
        self.listenForTransactionUpdates()
        
        /// Initialise handler for promotional offer
        if #available(iOS 16.4, *) {
            self.handlePromotionalOffer(success: { _ in
                
            }, failure: { _ in
                
            })
        }
    }
}

// MARK: - Transaction Listener Method
@available(iOS 15.0, *)
extension IAPManager {
    
    ///  This Method Listen about pending transaction or some refund transaction so here we can finish that transaction
    private func listenForTransactionUpdates() {
        Task {
            for await verificationResult in Transaction.updates {
                switch verificationResult {
                case .verified(let transaction):
                    Task {
                        await transaction.finish()
                        debugPrint(transaction)
                    }
                case .unverified(_, let error):
                    debugPrint("Unverified transaction: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Product load and purchase
@available(iOS 15.0, *)
extension IAPManager {
    
    /// This Method help to load Products with productIDs supplied in argument
    /// It will return all available Products in success callback
    /// It will return failure in enum if no product loaded Then inValidProductIds if some product is loaded then return Ids of product that not loaded and error if some error occurs in between execution
    func loadProducts(productIDs: [String], result: @escaping FlutterResult) {
        Task {
            do {
                let availableProducts = try await Product.products(for: productIDs)
                
                var products: [[String: Any]] = []
                for product in availableProducts {
                    var json: [String: Any] = [:]
                    json["productId"] = product.id
                    json["price"] = "\(product.price)"
                    json["currency"] = product.priceFormatStyle.currencyCode
                    json["localizedPrice"] = product.displayPrice
                    json["title"] = product.displayName
                    json["description"] = product.description
                    if let introOffer = product.subscription?.introductoryOffer {
                        json["introductoryPrice"] = "\(introOffer.price)"
                        json["introductoryPricePaymentModeIOS"] = introOffer.paymentMode.rawValue
                        json["introductoryPriceNumberOfPeriodsIOS"] = introOffer.period.unit.debugDescription
                        json["introductoryPriceSubscriptionPeriodIOS"] = introOffer.period.value.description
                        json["introductoryPriceNumberIOS"] = "\(introOffer.price)"
                    }
                    if let subscriptionPeriod = product.subscription?.subscriptionPeriod {
                        json["subscriptionPeriodNumberIOS"] = "\(subscriptionPeriod.value)"
                        json["subscriptionPeriodUnitIOS"] = "\(subscriptionPeriod.unit)"
                    }
                    products.append(json)
                }
                
                
                if availableProducts.count == productIDs.count {
                    self.isProductLoaded = true
                    self.products = availableProducts
                    DispatchQueue.main.async {
                        result(products)
                    }
                } else if self.products.isEmpty {
                    DispatchQueue.main.async {
                        result("Product load failed")
                    }
                } else {
                    let loadedProductIDs = self.products.map { $0.id }
                    let failedProductIDs = productIDs.filter { !loadedProductIDs.contains($0) }
                    DispatchQueue.main.async {
                        result("Product load failed for \(failedProductIDs)")
                    }
                }
            } catch {
                debugPrint(error.localizedDescription)
                DispatchQueue.main.async {
                    result("Some product can't be loaded")
                }
            }
        }
    }
    
    /// This function is for purchase Product
    /// This function success completion return current product id if purchase success and verified
    ///  This function failure return PurchaseError enum if transaction have any problem or successful transaction cant verify then it simply return in error variable or if transaction get pending or userCanceled or unknown then return according it
    func purchaseProduct(_ productId: String, result: FlutterResult) {
        guard let product = self.products.first(where: { $0.id == productId }), let viewController = getTopViewController() else { return }
        Task {
            do {
                var result: Product.PurchaseResult
                if #available(iOS 18.2, *) {
                    result = try await product.purchase(confirmIn: viewController)
                } else {
                    // Fallback on earlier versions
                    result = try await product.purchase()
                }
                switch result {
                case let .success(.verified(transaction)):
                    Task {
                        await transaction.finish()
                        debugPrint("Completed purchase with Transaction: \(transaction)")
                        
                        let transactionData = [
                            "productId": transaction.productID,
                            "transactionId": "\(transaction.id)",
                            "transactionDate": "\(transaction.purchaseDate.timeIntervalSince1970)",
                            "originalTransactionDateIOS": "\(transaction.originalPurchaseDate.timeIntervalSince1970)",
                            "originalTransactionIdentifierIOS": "\(transaction.originalID)",
                            "transactionStateIOS": 1
                        ]
                        
                        /// For the consumable products only because currentEntitlements not return consumable products
                        /// Here we extra check we get transaction for product that we tried to purchase or not
                        /// If we get some other transaction then we return unknown error
                        if transaction.productType == .consumable {
                            if transaction.productID == product.id {
                                self.channel.invokeMethod("purchase-updated", arguments: self.getJsonString(transactionData))
                            } else {
                                self.channel.invokeMethod("purchase-error", arguments: self.getJsonString([
                                    "responseCode": 400,
                                    "debugMessage": "Purchase failed",
                                    "code": "E_PRODUCT_ID_MISMATCH",
                                    "message": "Something went wrong. Please contact support."
                                ]))
                            }
                            return
                        }
                        
                        /// Here we add currentEntitlements so we can re-verify about purchase and unlock premium according that
                        self.getActiveTransaction(success: { allPurchasedProductIds in
                            if allPurchasedProductIds.contains(where: { $0.productID == product.id }) {
                                self.channel.invokeMethod("purchase-updated", arguments: self.getJsonString(transactionData))
                            } else {
                                self.channel.invokeMethod("purchase-error", arguments: self.getJsonString([
                                    "responseCode": 400,
                                    "debugMessage": "Product ID mismatch after verification.",
                                    "code": "E_PRODUCT_ID_MISMATCH",
                                    "message": "Something went wrong. Please contact support."
                                ]))
                            }
                        }, failure: { error in
                            self.channel.invokeMethod("purchase-error", arguments: self.getJsonString([
                                "responseCode": 404,
                                "debugMessage": "Transaction not found.",
                                "code": "E_TRANSACTION_NOT_FOUND",
                                "message": "We couldn't verify your purchase. Please try again later."
                            ]))
                        })
                    }
                case let .success(.unverified(_, error)):
                    debugPrint("Unverified purchase. Might be jailbroken. Error: \(error.localizedDescription)")
                    self.channel.invokeMethod("purchase-error", arguments: self.getJsonString([
                        "responseCode": 403,
                        "debugMessage": "Unverified purchase. Possibly jailbroken device.",
                        "code": "E_UNVERIFIED_PURCHASE",
                        "message": "We couldn’t verify your purchase."
                    ]))
                    break
                case .pending:
                    self.channel.invokeMethod("purchase-error", arguments: self.getJsonString([
                        "responseCode": 202,
                        "debugMessage": "Purchase is pending approval.",
                        "code": "E_PURCHASE_PENDING",
                        "message": "Your purchase is pending. Please wait or check with your payment provider."
                    ]))
                    break
                case .userCancelled:
                    debugPrint("User Cancelled!")
                    self.channel.invokeMethod("purchase-error", arguments: self.getJsonString([
                        "responseCode": 499,
                        "debugMessage": "User cancelled the transaction.",
                        "code": "E_USER_CANCELLED",
                        "message": "You cancelled the transaction."
                    ]))
                    break
                @unknown default:
                    debugPrint("Unknown error while purchasing.")
                    self.channel.invokeMethod("purchase-error", arguments: self.getJsonString([
                        "responseCode": 520,
                        "debugMessage": "Unknown error occurred.",
                        "code": "E_UNKNOWN",
                        "message": "Something went wrong. Please try again later."
                    ]))
                }
            } catch {
                debugPrint("Exception during purchase: \(error.localizedDescription)")
                self.channel.invokeMethod("purchase-error", arguments: self.getJsonString([
                    "responseCode": 500,
                    "debugMessage": "\(error.localizedDescription)",
                    "code": "E_PURCHASE_EXCEPTION",
                    "message": "An unexpected error occurred. Please try again."
                ]))
            }
        }
    }
}

// MARK: - Transaction Information Methods
@available(iOS 15.0, *)
extension IAPManager {
    
    /// This function fetch all active transaction
    /// This functions success callback return productIds of currently active plans
    /// This function failure callback return failure message if no plan has been purchased or verified transaction is currently not active
    private func getActiveTransaction(success: @escaping ([Transaction]) -> Void, failure: @escaping FailureCallBack) {
        Task {
            var purchasedPlan: [Transaction] = []
            for await result in Transaction.currentEntitlements {
                switch result {
                case .verified(let transaction):
                    if transaction.revocationDate != nil { continue }
                    debugPrint(transaction)
                    purchasedPlan.append(transaction)
                case .unverified(_, let error):
                    debugPrint("Verification Failed: \(error.localizedDescription)")
                    break
                }
            }
            purchasedPlan.isEmpty ? failure("No active plan available") : success(purchasedPlan)
        }
    }
    
    func getPurchaseHistory(result: @escaping FlutterResult) {
        Task {
            var purchasedPlan: [Transaction] = []
            for await result in Transaction.currentEntitlements {
                switch result {
                case .verified(let transaction):
                    if transaction.revocationDate != nil { continue }
                    debugPrint(transaction)
                    purchasedPlan.append(transaction)
                case .unverified(_, _):
                    break
                }
            }
            var transactionData: [[String: Any]] = []
            for transaction in purchasedPlan {
                transactionData.append([
                    "productId": transaction.productID,
                    "transactionId": "\(transaction.id)",
                    "transactionDate": "\(transaction.purchaseDate.timeIntervalSince1970)",
                    "originalTransactionDateIOS": "\(transaction.originalPurchaseDate.timeIntervalSince1970)",
                    "originalTransactionIdentifierIOS": "\(transaction.originalID)"
                ])
            }
            result(transactionData)
        }
    }
    
    /// This function check transaction is of trial period or purchase period
    /// This will return expire date it it is in trial period
    func checkIsThisTrialPeriod(in transaction: Transaction) -> Date? {
        if #available(iOS 17.2, *) {
            if transaction.offer?.paymentMode == .freeTrial { return transaction.expirationDate }
        } else {
            if transaction.offerType == .introductory { return transaction.expirationDate }
        }
        return nil
    }
    
    /// This Function get all transaction details
    /// This function success callback return all purchased plan id
    /// This function failure callback return error message that user never purchased anything
    private func allTransactionOfUser(success: @escaping ([Transaction]) -> Void, failure: @escaping FailureCallBack) {
        Task {
            var allPurchasedProductIds: [Transaction] = []
            for await result in Transaction.all {
                switch result {
                case .unverified(_, let error):
                    debugPrint("Unverified Error: \(error.localizedDescription)")
                    break
                case .verified(let transaction):
                    allPurchasedProductIds.append(transaction)
                }
            }
            allPurchasedProductIds.isEmpty ? failure("No Plan Purchased before") : success(Array(allPurchasedProductIds))
        }
    }
}

// MARK: - Restore Purchase
@available(iOS 15.0, *)
extension IAPManager {
    
    /// This function is for restore purchase
    /// This functions success callback return available productIds that is currently active
    /// This function failure callback return enum in which if user purchased before but that is expired, user never purchased or any other error message
    func restorePurchases(success: @escaping ([Transaction]) -> Void, failure: @escaping ((RestoreError) -> Void)) {
        Task {
            do {
                try await AppStore.sync()
                self.getActiveTransaction(success: { activeTransaction in
                    DispatchQueue.main.async {
                        success(activeTransaction)
                    }
                }, failure: { error in
                    /// Fetching All transaction of user in this app
                    self.allTransactionOfUser(success: { _ in
                        DispatchQueue.main.async {
                            failure(.expired)
                        }
                    }, failure: { _ in
                        DispatchQueue.main.async {
                            failure(.neverPurchased)
                        }
                    })
                })
            } catch {
                debugPrint(error.localizedDescription)
                DispatchQueue.main.async {
                    failure(.error(error.localizedDescription))
                }
            }
        }
    }
}

// MARK: - Promotional Offer Handler
@available(iOS 15.0, *)
extension IAPManager {
    
    /// This is for promotional purchase
    /// This function return success completion for productId of try to purchase product if purchased successfully
    /// This function return failure completion for any error in purchase
    @available(iOS 16.4, *)
    private func handlePromotionalOffer(success: @escaping (Transaction) -> Void, failure: @escaping (PurchaseError) -> Void) {
        Task {
            //            for await purchaseIntent in PurchaseIntent.intents {
            //                self.purchaseProduct(purchaseIntent.product.id, success: { purchasedProductIds in
            //                    DispatchQueue.main.async {
            //                        success(purchasedProductIds)
            //                    }
            //                }, failure: { error in
            //                    DispatchQueue.main.async {
            //                        failure(error)
            //                    }
            //                })
            //            }
        }
    }
    
    private func getTopViewController() -> UIViewController? {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else { return nil }
        var topVC = window.rootViewController
        while let presentedVC = topVC?.presentedViewController {
            topVC = presentedVC
        }
        return topVC
    }
}

// MARK: - Product Helping method
@available(iOS 15.0, *)
extension IAPManager {
    /// This function return available product list
    func getProductsData() -> [Product] {
        return self.products
    }
    
    /// This function find intro offer in product if plan have that offer and check user is eligible for it or not
    /// If user eligible for offer then it return subscription offer
    func getIntroOffer(from product: Product) async -> Product.SubscriptionOffer? {
        if let introOffer = product.subscription?.introductoryOffer, (await product.subscription?.isEligibleForIntroOffer == true) {
            return introOffer
        }
        return nil
    }
}

// MARK: - Util Methods
extension IAPManager {
    private func getJsonString(_ dict: [String: Any]) -> String? {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [])
            return String(data: jsonData, encoding: .utf8)
        } catch {
            debugPrint("Error: \(error.localizedDescription)")
        }
        return nil
    }
}
