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

    private weak var webView: WKWebView?
    private let presenter: @MainActor () -> UIViewController?
    private var currentNonce: String?

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
        case "apple": startApple()
        default: break
        }
    }

    // MARK: - Google

    /// El "client ID" de iOS sale del archivo GoogleService-Info.plist de Firebase
    private static func googleClientID() -> String? {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
        return dict["CLIENT_ID"] as? String
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

    private func startApple() {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
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
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let nonce = currentNonce else {
            callWeb("onAppleSignInError", "Sign in with Apple failed. Please try again.")
            return
        }
        currentNonce = nil
        callWeb("onAppleSignInResult", idToken, nonce)
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        currentNonce = nil
        if (error as? ASAuthorizationError)?.code == .canceled { return }   // ha cerrado la ventana
        callWeb("onAppleSignInError", "Sign in with Apple failed. Please try again.")
    }
}
