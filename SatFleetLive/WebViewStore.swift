//
//  WebViewStore.swift
//  SatFleet Live (iOS)
//
//  El "marco" de la app: abre satfleetlive.com y se encarga de
//  - los enlaces (los de otras webs y los de correo, WhatsApp... salen fuera),
//  - los permisos de camara y brujula para el AR,
//  - los avisos de la web (alert / confirm),
//  - detectar cuando no hay conexion y recargar sola cuando vuelve,
//  - la ubicacion: la da la app (LocationBridge.swift), asi solo se pide permiso una vez.
//

import SwiftUI
import WebKit
import Network

/// Direccion que abre la app al arrancar.
let satfleetHomeURL = URL(string: "https://satfleetlive.com")!

// MARK: - Colores de marca

extension UIColor {
    static let satfleetBackground = UIColor(red: 15/255, green: 15/255, blue: 18/255, alpha: 1)
    static let satfleetPurple = UIColor(red: 156/255, green: 39/255, blue: 176/255, alpha: 1)
}

extension Color {
    static let satfleetBackground = Color(uiColor: .satfleetBackground)
    static let satfleetPurple = Color(uiColor: .satfleetPurple)
}

// MARK: - La "ventana" de la web para la pantalla principal

struct WebView: UIViewRepresentable {
    let store: WebViewStore

    func makeUIView(context: Context) -> WKWebView {
        store.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - El cerebro del marco

@MainActor
final class WebViewStore: NSObject, ObservableObject {

    /// true cuando no se ha podido cargar la web (se ve la pantalla "Sin conexion").
    @Published var isOffline = false
    /// true en cuanto la web ha terminado de cargar al menos una vez.
    @Published var hasLoadedOnce = false

    let webView: WKWebView
    private var locationBridge: LocationBridge?
    private var authBridge: AuthBridge?
    private var purchaseBridge: PurchaseBridge?
    private let networkMonitor = NWPathMonitor()
    private var hasNetwork = true

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true               // la camara del AR se ve dentro de la pagina
        config.mediaTypesRequiringUserActionForPlayback = []   // videos de fondo sin tener que tocarlos
        config.websiteDataStore = .default()                   // guarda sesion y ajustes entre aperturas
        // Marca para que la web sepa que esta dentro de la app de iOS
        config.applicationNameForUserAgent = "Mobile/15E148 SatFleetLiveiOS/1.0"

        let marker = WKUserScript(
            source: "window.SatFleetIOS = { version: '1.0' };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(marker)

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true     // deslizar desde el borde = atras
        webView.isOpaque = false
        webView.backgroundColor = .satfleetBackground
        webView.scrollView.backgroundColor = .satfleetBackground
        webView.scrollView.bounces = false

        // Ubicacion: la web se la pide a la app en vez de a Safari (un solo permiso)
        let bridge = LocationBridge(webView: webView)
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: LocationBridge.javascript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.add(bridge, name: LocationBridge.handlerName)
        locationBridge = bridge

        // Inicio de sesion nativo (Apple y Google)
        let auth = AuthBridge(webView: webView) { [weak self] in self?.topViewController() }
        controller.add(auth, name: AuthBridge.handlerName)
        authBridge = auth

        // Compras con Apple (RevenueCat)
        let purchases = PurchaseBridge(webView: webView) { [weak self] in self?.topViewController() }
        controller.add(purchases, name: PurchaseBridge.handlerName)
        purchaseBridge = purchases

        // Notificaciones nativas (lanzamientos y avisos de pases)
        controller.addUserScript(WKUserScript(
            source: PushManager.javascript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.add(PushManager.shared, name: PushManager.handlerName)

        #if DEBUG
        // Solo en pruebas: permite inspeccionar la web desde Safari del Mac
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif

        startNetworkMonitor()
        webView.load(URLRequest(url: satfleetHomeURL))
        PushManager.shared.attach(webView: webView)
    }

    // MARK: Acciones de los botones

    func reload() {
        if webView.url == nil {
            webView.load(URLRequest(url: satfleetHomeURL))
        } else {
            webView.reload()
        }
    }

    func retry() {
        isOffline = false
        reload()
    }

    // MARK: Vigilar la conexion

    private func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let online = (path.status == .satisfied)
            Task { @MainActor in
                self?.networkChanged(online: online)
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "com.satfleetlive.network"))
    }

    private func networkChanged(online: Bool) {
        let cameBack = online && !hasNetwork
        hasNetwork = online
        // Si estabamos en "Sin conexion" y vuelve internet, recargamos solos
        if cameBack && isOffline {
            retry()
        }
    }

    // MARK: Ayudantes

    private func isOwnHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "satfleetlive.com" || h.hasSuffix(".satfleetlive.com")
    }

    private func isOwnSite(_ url: URL) -> Bool {
        isOwnHost(url.host ?? "")
    }

    private func openOutside(_ url: URL) {
        UIApplication.shared.open(url)
    }

    private func handleLoadError(_ error: Error) {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else { return }
        let offlineCodes = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorDataNotAllowed
        ]
        if offlineCodes.contains(e.code) {
            isOffline = true
        }
    }

    /// La pantalla que esta visible ahora mismo (para mostrar los avisos encima).
    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - Navegacion: que hacer con cada enlace, cuando termina de cargar, errores

extension WebViewStore: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = (url.scheme ?? "").lowercased()

        // 1. Enlaces especiales (correo, telefono, WhatsApp, YouTube...): los abre el sistema
        let webSchemes: Set<String> = ["http", "https", "about", "blob", "data"]
        if !webSchemes.contains(scheme) {
            openOutside(url)
            decisionHandler(.cancel)
            return
        }

        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isMainFrame && (scheme == "http" || scheme == "https") {
            // 2. Portal de suscripcion de Stripe: en Safari (igual que en Android)
            if (url.host ?? "").contains("billing.stripe.com") {
                openOutside(url)
                decisionHandler(.cancel)
                return
            }
            // 3. Si el usuario pulsa un enlace a otra web, se abre en Safari
            if navigationAction.navigationType == .linkActivated && !isOwnSite(url) {
                openOutside(url)
                decisionHandler(.cancel)
                return
            }
        }

        // 4. Todo lo demas se queda dentro de la app
        decisionHandler(.allow)
    }

    // Al cambiar de pagina, se cancelan los seguimientos de ubicacion de la anterior
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        locationBridge?.reset()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasLoadedOnce = true
        isOffline = false
        PushManager.shared.pageDidFinish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    // Si iOS cierra la web por falta de memoria (puede pasar con el 3D), la recargamos
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reload()
    }
}

// MARK: - Ventanas nuevas, permisos y avisos de la web

extension WebViewStore: WKUIDelegate {

    // Enlaces que quieren abrir ventana nueva (target="_blank" o window.open)
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            if isOwnSite(url) {
                webView.load(navigationAction.request)   // nuestra web: en la misma pantalla
            } else {
                openOutside(url)                         // otra web: en Safari
            }
        }
        return nil
    }

    // Camara (AR): a nuestra web se le da permiso directo, sin preguntar dos veces
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(isOwnHost(origin.host) ? .grant : .prompt)
    }

    // Brujula y movimiento (AR): igual que la camara
    func webView(_ webView: WKWebView,
                 requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(isOwnHost(origin.host) ? .grant : .prompt)
    }

    // alert() de la web
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable () -> Void) {
        guard let presenter = topViewController() else {
            completionHandler()
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    // confirm() de la web
    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let presenter = topViewController() else {
            completionHandler(false)
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Texts.cancel, style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }

    // prompt() de la web
    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        guard let presenter = topViewController() else {
            completionHandler(nil)
            return
        }
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: Texts.cancel, style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text ?? "")
        })
        presenter.present(alert, animated: true)
    }
}