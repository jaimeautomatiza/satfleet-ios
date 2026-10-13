//
//  AuthBridge.swift
//  SatFleet Live (iOS)
//
//  Inicio de sesion nativo, igual que en la app de Android:
//  la web (account.html) pide "entra con Apple" o "entra con Google",
//  la app abre la ventana oficial de Apple o de Google, y devuelve a la web
//  el "pase" (token) para que Firebase inicie la sesion.
//
//  Lo que llega a la web:
//    window.onGoogleSignInResult(token)        (lo mismo que en Android)
//    window.onGoogleSignInError(mensaje)
//    window.onAppleSignInResult(token, nonce)
//    window.onAppleSignInError(mensaje)
//
//  Borrado de cuenta con Apple (norma 5.1.1(v) de Apple):
//    "appleReauth" -> ventana de Apple otra vez para confirmar
//                     -> window.onAppleReauthResult(token, nonce, codigo)
//                     -> window.onAppleReauthCancelled()   (ha cerrado la ventana)
//                     -> window.onAppleReauthError(mensaje)
//    "appleRevoke" -> la app revoca el acceso de Apple con ese codigo (via Firebase)
//                     -> window.onAppleRevokeResult()
//                     -> window.onAppleRevokeError(mensaje)
//

import Foundation
import UIKit
import WebKit
import AuthenticationServices
import CryptoKit
import Security
import GoogleSignIn

@MainActor
final class AuthBridge: NSObject, WKScriptMessageHandler {

    static let handlerName = "satfleetAuth"

    /// El mismo "Web client ID" que usa la app de Android
    private static let webClientID = "369952976257-cks64kbra8hi3bu1v8te1r6starvninn.apps.googleusercontent.com"

    /// Para que sirve la ventana de Apple que esta abierta ahora
    private enum AppleMode { case signIn, reauth }

    private weak var webView: WKWebView?
    private let presenter: @MainActor () -> UIViewController?
    private var currentNonce: String?
    private var appleMode: AppleMode = .signIn
    private var isRevoking = false

    init(webView: WKWebView, presenter: @escaping @MainActor () -> UIViewController?) {
        self.webView = webView
        self.presenter = presenter
        super.init()
    }

    // MARK: - Pedidos que llegan de la web

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        switch action {
        case "google": startGoogle()
        case "apple": startApple(mode: .signIn)
        case "appleReauth": startApple(mode: .reauth)
        case "appleRevoke":
            let code = body["code"] as? String ?? ""
            let idToken = body["idToken"] as? String ?? ""
            Task { await revokeApple(code: code, idToken: idToken) }
        default: break
        }
    }

    // MARK: - Datos del archivo GoogleService-Info.plist de Firebase

    private static func firebaseValue(_ key: String) -> String? {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
        return dict[key] as? String
    }

    // MARK: - Google

    /// El "client ID" de iOS sale del archivo GoogleService-Info.plist de Firebase
    private static func googleClientID() -> String? {
        firebaseValue("CLIENT_ID")
    }

    private func startGoogle() {
        guard let clientID = Self.googleClientID() else {
            callWeb("onGoogleSignInError", "Google sign-in is not configured.")
            return
        }
        guard let vc = presenter() else {
            callWeb("onGoogleSignInError", "Sign in failed. Please try again.")
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID, serverClientID: Self.webClientID)
        GIDSignIn.sharedInstance.signOut()   // asi siempre sale el selector de cuentas, como en Android

        GIDSignIn.sharedInstance.signIn(withPresenting: vc) { [weak self] result, error in
            let token = result?.user.idToken?.tokenString
            let cancelled = (error as NSError?)?.code == -5   // -5 = el usuario ha cerrado la ventana
            Task { @MainActor in
                guard let self else { return }
                if let token {
                    self.callWeb("onGoogleSignInResult", token)
                } else if !cancelled {
                    self.callWeb("onGoogleSignInError", "Sign in failed. Please try again.")
                }
            }
        }
    }

    // MARK: - Apple

    private func startApple(mode: AppleMode) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        appleMode = mode
        let request = ASAuthorizationAppleIDProvider().createRequest()
        // Para entrar pedimos nombre y email; para confirmar el borrado no hace falta
        request.requestedScopes = (mode == .signIn) ? [.fullName, .email] : []
        request.nonce = Self.sha256(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    /// Revoca el acceso de Apple con el codigo nuevo. Lo hace Firebase (la misma
    /// llamada que usa su SDK oficial de iOS), que tiene la clave de Apple configurada.
    private func revokeApple(code: String, idToken: String) async {
        guard !isRevoking else { return }
        guard !code.isEmpty, !idToken.isEmpty,
              let apiKey = Self.firebaseValue("API_KEY"),
              let url = URL(string: "https://identitytoolkit.googleapis.com/v2/accounts:revokeToken?key=\(apiKey)") else {
            callWeb("onAppleRevokeError", "Could not confirm with Apple. Please try again.")
            return
        }
        isRevoking = true
        defer { isRevoking = false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Bundle.main.bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        if let appID = Self.firebaseValue("GOOGLE_APP_ID") {
            request.setValue(appID, forHTTPHeaderField: "X-Firebase-GMPID")
        }
        let body: [String: String] = [
            "providerId": "apple.com",
            "tokenType": "3",          // 3 = codigo de autorizacion de Apple
            "token": code,
            "idToken": idToken
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                callWeb("onAppleRevokeResult")
            } else {
                let detail = Self.firebaseErrorMessage(data) ?? "HTTP \(status)"
                callWeb("onAppleRevokeError", "Could not revoke Sign in with Apple (\(detail)). Please try again.")
            }
        } catch {
            callWeb("onAppleRevokeError", "Could not connect. Please check your connection and try again.")
        }
    }

    /// Saca el mensaje de error que devuelve Firebase, por ejemplo "INVALID_ID_TOKEN"
    private static func firebaseErrorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }

    /// Codigo aleatorio de un solo uso que exige Firebase para entrar con Apple
    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Respuestas a la web

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

// MARK: - Ventana oficial de "Iniciar sesion con Apple"

extension AuthBridge: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        presenter()?.view.window ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        let mode = appleMode
        appleMode = .signIn
        let errorFunction = (mode == .reauth) ? "onAppleReauthError" : "onAppleSignInError"

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let nonce = currentNonce else {
            currentNonce = nil
            callWeb(errorFunction, "Sign in with Apple failed. Please try again.")
            return
        }
        currentNonce = nil

        switch mode {
        case .signIn:
            callWeb("onAppleSignInResult", idToken, nonce)
        case .reauth:
            // El codigo nuevo de un solo uso, necesario para revocar el acceso
            guard let codeData = credential.authorizationCode,
                  let code = String(data: codeData, encoding: .utf8) else {
                callWeb("onAppleReauthError", "Sign in with Apple failed. Please try again.")
                return
            }
            callWeb("onAppleReauthResult", idToken, nonce, code)
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        let mode = appleMode
        appleMode = .signIn
        currentNonce = nil
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled   // ha cerrado la ventana

        if mode == .reauth {
            if cancelled {
                callWeb("onAppleReauthCancelled")
            } else {
                callWeb("onAppleReauthError", "Sign in with Apple failed. Please try again.")
            }
            return
        }
        if cancelled { return }
        callWeb("onAppleSignInError", "Sign in with Apple failed. Please try again.")
    }
}