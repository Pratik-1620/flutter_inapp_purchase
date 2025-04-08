
import Foundation
import StoreKit
import Flutter

public class FlutterInappPurchasePlugin: NSObject, FlutterPlugin {
    
    public static func register(with registrar: any FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_inapp", binaryMessenger: registrar.messenger())
        let instance = FlutterInappPurchasePlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        IAPManager.shared.channel = channel
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "getPlatformVersion" {
            result(FlutterMethodNotImplemented)
        } else if call.method == "canMakePayments" {
            if #available(iOS 15.0, *) {
                result("\(AppStore.canMakePayments)")
            } else {
                result(FlutterMethodNotImplemented)
            }
        } else if call.method == "endConnection" {
            result(FlutterMethodNotImplemented)
        } else if call.method == "getItems" {
            if let argument = call.arguments as? [String: Any], let productIds = argument["skus"] as? [String] {
                IAPManager.shared.loadProducts(productIDs: productIds, result: result)
            }
        } else if call.method == "buyProduct" {
            if let argument = call.arguments as? [String: Any], let productId = argument["sku"] as? String {
                IAPManager.shared.purchaseProduct(productId, result: result)
            }
        } else if call.method == "requestProductWithOfferIOS" {
            result(FlutterMethodNotImplemented)
        } else if call.method == "getPromotedProduct" {
            result(FlutterMethodNotImplemented)
        } else if call.method == "requestPromotedProduct" {
            result(FlutterMethodNotImplemented)
        } else if call.method == "requestReceipt" {
            result(FlutterMethodNotImplemented)
        } else if call.method == "getPendingTransactions" {
            IAPManager.shared.getPendingTransaction(result: result)
        } else if call.method == "finishTransaction" {
            if let argument = call.arguments as? [String: Any], let transactionId = argument["transactionIdentifier"] as? String {
                IAPManager.shared.completeTransaction(id: transactionId, result: result)
            }
        } else if call.method == "clearTransaction" {
            result(FlutterMethodNotImplemented) // Dont know about it
        } else if call.method == "getAvailableItems" {
            IAPManager.shared.getPurchaseHistory(result: result)
        } else if call.method == "getAppStoreInitiatedProducts" {
            result(FlutterMethodNotImplemented)
        } else if call.method == "showRedeemCodesIOS" {
            result(FlutterMethodNotImplemented)
        } else {
            result(FlutterMethodNotImplemented)
        }
    }
    
}
