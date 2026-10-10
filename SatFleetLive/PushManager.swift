//
//  PushManager.swift
//  SatFleet Live (iOS)
//
//  Notificaciones nativas de iPhone/iPad con Firebase (el mismo sistema que usa el Worker):
//  - Pide permiso de notificaciones una vez, al abrir la app.
//  - Consigue el "token" de Firebase del aparato y lo apunta al tema
//    "todos_los_usuarios" (avisos de lanzamientos, igual que Android).
//  - Le da a la web ese token y el estado del permiso, para que Next Passes
//    pueda programar avisos de pases sin tocar nada de la web.
//  - Al tocar una notificacion, abre la pagina que indica (campo "url").
//

import Foundation
import UIKit
import WebKit
import UserNotifications
import FirebaseCore
import FirebaseMessaging

// MARK: - Arranque de la app (necesario para las notificaciones)

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        PushManager.shared.start()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("No se pudo registrar para notificaciones: \(error.localizedDescription)")
    }

    // Firebase nos da (o renueva) el token del aparato
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        PushManager.shared.tokenReceived(fcmToken)
    }

    // Con la app abierta, las notificaciones tambien se muestran arriba
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    // El usuario toca una notificacion: abrimos su pagina
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let urlString = response.notification.request.content.userInfo["url"] as? String
        PushManager.shared.openFromNotification(urlString)
        // Aviso "Despegue en 2 horas": empieza la cuenta atras en la pantalla de bloqueo
        if let launchId = response.notification.request.content.userInfo["satfleetFollowLaunch"] as? String {
            LiveActivityManager.shared.startFromReminder(launchId)
        }
    }
}

// MARK: - Gestor de notificaciones

@MainActor
final class PushManager: NSObject, WKScriptMessageHandler {

    static let shared = PushManager()
    static let handlerName = "satfleetPush"
    private static let launchesTopic = "todos_los_usuarios"

    private weak var webView: WKWebView?
    private var fcmToken: String?
    private var permission = "default"       // "default" | "granted" | "denied"
    private var askedThisLaunch = false
    private var pendingURL: URL?

    // MARK: Arranque

    /// Lo llama AppDelegate al abrir la app
    func start() {
        refreshPermission()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// Lo llama WebViewStore al crear la web
    func attach(webView: WKWebView) {
        self.webView = webView
        if let url = pendingURL {
            pendingURL = nil
            webView.load(URLRequest(url: url))
        }
    }

    /// Lo llama WebViewStore cada vez que termina de cargar una pagina
    func pageDidFinish() {
        sendStateToWeb()
        askPermissionIfNeeded()
    }

    @objc private func appBecameActive() {
        // Por si el usuario ha activado o quitado las notificaciones en Ajustes
        refreshPermission()
    }

    // MARK: Permiso

    private func refreshPermission() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            applyStatus(settings.authorizationStatus)
        }
    }

    private func applyStatus(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            permission = "granted"
        case .denied:
            permission = "denied"
        default:
            permission = "default"
        }
        subscribeToLaunchesIfPossible()
        sendStateToWeb()
    }

    /// Primera vez que se abre la app: pedimos permiso (como Android)
    private func askPermissionIfNeeded() {
        guard permission == "default", !askedThisLaunch else { return }
        askedThisLaunch = true
        Task { _ = await requestPermission() }
    }

    private func requestPermission() async -> String {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let updated = await center.notificationSettings()
        applyStatus(updated.authorizationStatus)
        return permission
    }

    // MARK: Token y tema de lanzamientos

    func tokenReceived(_ token: String?) {
        guard let token, !token.isEmpty else { return }
        fcmToken = token
        subscribeToLaunchesIfPossible()
        sendStateToWeb()
    }

    private func subscribeToLaunchesIfPossible() {
        guard permission == "granted", fcmToken != nil else { return }
        Messaging.messaging().subscribe(toTopic: Self.launchesTopic) { error in
            if let error {
                print("Error al apuntarse a lanzamientos: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Abrir la pagina de una notificacion

    func openFromNotification(_ urlString: String?) {
        guard let urlString, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        if let webView {
            webView.load(URLRequest(url: url))
        } else {
            pendingURL = url   // la app se estaba abriendo: la cargamos en cuanto exista la web
        }
    }

    // MARK: Comunicacion con la web

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        if action == "requestPermission" {
            Task {
                let result = await requestPermission()
                callWeb("permissionResult", result, fcmToken ?? "")
            }
        }
    }

    private func sendStateToWeb() {
        callWeb("update", permission, fcmToken ?? "")
    }

    private func callWeb(_ function: String, _ args: String...) {
        let encoded = args.map { arg -> String in
            if let data = try? JSONEncoder().encode(arg), let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "\"\""
        }
        let js = "window.__satfleetPush && window.__satfleetPush.\(function)(\(encoded.joined(separator: ", ")));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: Script que se mete en cada pagina
    //
    // Dentro de una app no existe la API de notificaciones del navegador.
    // Este script la "imita": Notification.permission y Notification.requestPermission()
    // hablan con la app, y window.webFcmToken lleva el token de Firebase del aparato.
    // Asi Next Passes funciona igual que en el navegador, sin cambiar la web.

    static let javascript = """
    (function () {
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.satfleetPush;
      if (!handler) { return; }
      var PERM_KEY = 'satfleet_ios_notif_permission';
      var TOKEN_KEY = 'satfleet_ios_fcm_token';
      var pending = [];

      function readPermission() {
        try { return localStorage.getItem(PERM_KEY) || 'default'; } catch (e) { return 'default'; }
      }
      try {
        var saved = localStorage.getItem(TOKEN_KEY);
        if (saved) { window.webFcmToken = saved; }
      } catch (e) {}

      var AppNotification = function () {};
      Object.defineProperty(AppNotification, 'permission', { get: readPermission });
      AppNotification.requestPermission = function (callback) {
        return new Promise(function (resolve) {
          pending.push(function (result) {
            resolve(result);
            if (typeof callback === 'function') { callback(result); }
          });
          handler.postMessage({ action: 'requestPermission' });
        });
      };
      try {
        Object.defineProperty(window, 'Notification', { configurable: true, writable: true, value: AppNotification });
      } catch (e) {
        window.Notification = AppNotification;
      }

      // Dentro de la app cuenta como "instalada"
      try {
        Object.defineProperty(Navigator.prototype, 'standalone', { configurable: true, get: function () { return true; } });
      } catch (e) {
        try { Object.defineProperty(navigator, 'standalone', { configurable: true, value: true }); } catch (e2) {}
      }

      window.__satfleetPush = {
        update: function (permission, token) {
          try {
            if (permission) { localStorage.setItem(PERM_KEY, permission); }
            if (token) { localStorage.setItem(TOKEN_KEY, token); }
          } catch (e) {}
          if (token) { window.webFcmToken = token; }
        },
        permissionResult: function (permission, token) {
          window.__satfleetPush.update(permission, token);
          var list = pending;
          pending = [];
          list.forEach(function (fn) { try { fn(permission); } catch (e) {} });
        }
      };
    })();
    """
}