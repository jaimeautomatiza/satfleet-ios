//
//  PurchaseBridge.swift
//  SatFleet Live (iOS)
//
//  Compra del Premium con Apple, a traves de RevenueCat (igual que Android con Google Play).
//  La web (account.html) pide:
//    "price"   -> precio real en la moneda del usuario   -> window.onIOSPriceInfo(precio)
//    "buy"     -> comprar (con el UID de Firebase)        -> window.onIOSPurchaseDone()
//    "restore" -> restaurar compras anteriores            -> window.onIOSPurchaseDone()
//    "manage"  -> abrir la gestion de suscripciones de Apple
//

import Foundation
import UIKit
import WebKit
import RevenueCat

@MainActor
final class PurchaseBridge: NSObject, WKScriptMessageHandler {

    static let handlerName = "satfleetPurchase"

    /// Clave publica de RevenueCat para iOS (es publica por diseno)
    private static let revenueCatAPIKey = "appl_JJPdXphLZeRwGdriZORoOnEAGrA"

    private weak var webView: WKWebView?
    private let presenter: @MainActor () -> UIViewController?
    private var isBusy = false

    init(webView: WKWebView, presenter: @escaping @MainActor () -> UIViewController?) {
        self.webView = webView
        self.presenter = presenter
        super.init()
        if !Purchases.isConfigured {
            Purchases.logLevel = .warn
            Purchases.configure(withAPIKey: Self.revenueCatAPIKey)
        }
    }

    // MARK: - Pedidos que llegan de la web

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        let uid = body["uid"] as? String ?? ""

        switch action {
        case "price":
            Task { await sendPrice() }
        case "buy":
            guard !uid.isEmpty, !isBusy else { return }
            Task { await buy(uid: uid) }
        case "restore":
            guard !uid.isEmpty, !isBusy else { return }
            Task { await restore(uid: uid) }
        case "manage":
            Task { await manage() }
        default:
            break
        }
    }

    // MARK: - Acciones

    /// El paquete mensual de la oferta actual (la misma que usa Android)
    private func currentPackage() async throws -> Package? {
        let offerings = try await Purchases.shared.offerings()
        return offerings.current?.availablePackages.first
    }

    private func sendPrice() async {
        guard let package = try? await currentPackage() else { return }
        callWeb("onIOSPriceInfo", package.storeProduct.localizedPriceString)
    }

    private func buy(uid: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            // 1. Vincular la cuenta de Firebase con RevenueCat
            _ = try await Purchases.shared.logIn(uid)
            // 2. Pedir el producto
            guard let package = try await currentPackage() else {
                showAlert("No subscription products found. Please try again later.")
                return
            }
            // 3. Ventana oficial de compra de Apple
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return }
            if !result.customerInfo.entitlements.active.isEmpty {
                callWeb("onIOSPurchaseDone")
            }
        } catch {
            if Self.isCancellation(error) { return }
            showAlert("The purchase could not be completed. Please try again.")
        }
    }

    private func restore(uid: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await Purchases.shared.logIn(uid)
            let info = try await Purchases.shared.restorePurchases()
            if info.entitlements.active.isEmpty {
                showAlert("No active subscription was found for this Apple ID.")
            } else {
                callWeb("onIOSPurchaseDone")
            }
        } catch {
            showAlert("Purchases could not be restored. Please try again.")
        }
    }

    private func manage() async {
        do {
            try await Purchases.shared.showManageSubscriptions()
        } catch {
            if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                _ = await UIApplication.shared.open(url)
            }
        }
    }

    // MARK: - Ayudantes

    private static func isCancellation(_ error: Error) -> Bool {
        (error as NSError).code == ErrorCode.purchaseCancelledError.rawValue
    }

    private func showAlert(_ message: String) {
        guard let vc = presenter() else { return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        vc.present(alert, animated: true)
    }

    /// Llama a window.<funcion>(argumentos...) en la pagina, con el texto bien escapado
    private func callWeb(_ function: String, _ args: String...) {
        let encoded = args.map { arg -> String in
            if let data = try? JSONEncoder().encode(arg), let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "\"\""
        }
        let js = "window.\(function) && window.\(function)(\(encoded.joined(separator: ", ")));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}