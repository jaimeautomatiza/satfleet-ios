//
//  LiveActivityManager.swift
//  SatFleet Live (iOS)
//
//  Cuenta atras del proximo lanzamiento en la pantalla de bloqueo (Live Activity)
//  y en la Dynamic Island. GRATIS para todos y SIN llamadas nuevas al Worker:
//
//  - La pagina Launches (launches.html) muestra un boton en cada lanzamiento,
//    solo dentro de esta app y solo en iPhones que admiten Live Activities.
//  - Si faltan menos de 7 horas: "Follow on Lock Screen" -> empieza al momento.
//    (Apple corta las Live Activities a las 8 horas; asi queda 1 hora para el T+.)
//  - Si falta mas: "Remind me 2 h before" -> el iPhone programa un aviso local
//    2 horas antes. Al tocarlo se abre la app y la cuenta atras empieza sola.
//  - Si el lanzamiento se retrasa: cada vez que se abre la app, se miran los datos
//    de lanzamientos que la web YA tiene guardados (localStorage
//    "satfleet_launches_v1", el mismo que usan index y launches) y se corrige la
//    hora, el estado y el aviso. Sin descargar nada.
//  - Se quita sola 1 hora despues del lanzamiento (al abrir la app), al pulsar
//    "Stop", al deslizarla, al seguir otro lanzamiento o por el limite de Apple.
//
//  En iPad no hay Live Activities: alli el boton no aparece y esto no hace nada.
//

import Foundation
import UIKit
import WebKit
import UserNotifications
import ActivityKit

@MainActor
final class LiveActivityManager: NSObject, WKScriptMessageHandler {

    static let shared = LiveActivityManager()
    static let handlerName = "satfleetLive"

    // MARK: Ajustes

    /// Se puede empezar al momento si faltan como mucho estas horas
    static let followWindowHours: Double = 7
    /// El aviso llega estas horas antes del lanzamiento
    static let reminderHours: Double = 2
    /// La Live Activity se quita cuando ha pasado esto desde el lanzamiento
    private static let endAfterLaunch: TimeInterval = 60 * 60
    /// No se empieza si el lanzamiento fue hace mas de esto
    private static let lateStartLimit: TimeInterval = 30 * 60
    /// Cada cuanto se revisan los datos con la app abierta (sin internet: solo lee lo guardado)
    private static let syncEvery: TimeInterval = 5 * 60

    static let launchesURL = URL(string: "https://satfleetlive.com/launches.html")!
    private static let remindersKey = "satfleet_live_reminders_v1"

    // MARK: Datos

    struct SavedLaunch: Codable, Equatable {
        var id: String
        var rocket: String
        var mission: String
        var pad: String
        var net: Date
        var status: String
    }

    private struct Fresh {
        let net: Date
        let status: String
    }

    private weak var webView: WKWebView?
    private var pendingURL: URL?
    private var pendingStartId: String?
    private var syncTimer: Timer?
    private var isSyncing = false
    private var reminders: [String: SavedLaunch] = [:]

    private override init() {
        super.init()
        reminders = Self.loadReminders()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil
        )
    }

    // MARK: Conexion con la app

    /// Lo llama WebViewStore al crear la web
    func attach(webView: WKWebView) {
        self.webView = webView
        if let url = pendingURL {
            pendingURL = nil
            open(url)
        }
    }

    /// Lo llama WebViewStore cada vez que termina de cargar una pagina
    func pageDidFinish() {
        sendState()
        syncFromWeb()
    }

    /// Al tocar la Live Activity se abre la app con "satfleetlive://launches"
    func handleDeepLink(_ url: URL) {
        guard url.host?.lowercased() == "launches" else { return }
        open(Self.launchesURL)
    }

    /// Al tocar el aviso "Despegue en 2 horas" (lo llama AppDelegate)
    func startFromReminder(_ launchId: String) {
        pendingStartId = launchId
        if UIApplication.shared.applicationState == .active {
            processPendingStart()
        }
    }

    @objc private func appBecameActive() {
        processPendingStart()
        syncFromWeb()
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: Self.syncEvery, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncFromWeb() }
        }
    }

    @objc private func appWillResignActive() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func open(_ url: URL) {
        guard let webView else {
            pendingURL = url   // la app se esta abriendo: la cargamos cuando exista la web
            return
        }
        if webView.url?.path == url.path { return }   // ya estamos en esa pagina: no recargamos
        webView.load(URLRequest(url: url))
    }

    // MARK: ¿Se puede usar en este aparato?

    var isSupported: Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        if #available(iOS 16.2, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        return false
    }

    @available(iOS 16.2, *)
    private func currentActivity() -> Activity<LaunchActivityAttributes>? {
        Activity<LaunchActivityAttributes>.activities.first {
            $0.activityState == .active || $0.activityState == .stale
        }
    }

    private var followingId: String {
        if #available(iOS 16.2, *) {
            return currentActivity()?.attributes.launchId ?? ""
        }
        return ""
    }

    // MARK: Pedidos que llegan de la web

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "hello":
            sendState()
        case "follow":
            guard let launch = Self.parseLaunch(body["launch"]) else { sendState(); return }
            Task { await follow(launch) }
        case "unfollow":
            Task { await stopFollowing() }
        case "remind":
            guard let launch = Self.parseLaunch(body["launch"]) else { sendState(); return }
            Task { await remind(launch) }
        case "cancelReminder":
            if let id = body["id"] as? String {
                removeReminder(id)
                toast(Texts.isSpanish ? "Aviso cancelado." : "Reminder cancelled.")
            }
            sendState()
        default:
            break
        }
    }

    // MARK: Seguir un lanzamiento

    private func follow(_ launch: SavedLaunch) async {
        guard #available(iOS 16.2, *), isSupported else {
            toast(Texts.isSpanish
                  ? "Las Live Activities están desactivadas. Actívalas en Ajustes > SatFleet Live."
                  : "Live Activities are turned off. Turn them on in Settings > SatFleet Live.")
            sendState()
            return
        }
        if await startActivity(launch) {
            removeReminder(launch.id)
            toast(Texts.isSpanish
                  ? "Cuenta atrás activada en la pantalla de bloqueo."
                  : "Countdown added to your Lock Screen.")
        } else {
            toast(Texts.isSpanish
                  ? "No se pudo activar la cuenta atrás. Inténtalo de nuevo."
                  : "Could not start the countdown. Please try again.")
        }
        sendState()
    }

    private func stopFollowing() async {
        if #available(iOS 16.2, *) {
            for activity in Activity<LaunchActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        sendState()
    }

    @available(iOS 16.2, *)
    private func startActivity(_ launch: SavedLaunch) async -> Bool {
        // Solo una a la vez: si habia otra, se quita
        for activity in Activity<LaunchActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let attributes = LaunchActivityAttributes(
            launchId: launch.id,
            rocket: launch.rocket,
            mission: launch.mission,
            pad: launch.pad
        )
        let state = LaunchActivityAttributes.ContentState(net: launch.net, status: launch.status)
        // staleDate = hora del lanzamiento: a partir de ahi la pantalla pasa de T- a T+
        let content = ActivityContent(state: state, staleDate: launch.net)
        do {
            _ = try Activity<LaunchActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil          // sin notificaciones push: no hace falta el servidor
            )
            return true
        } catch {
            print("No se pudo empezar la Live Activity: \(error.localizedDescription)")
            return false
        }
    }

    @available(iOS 16.2, *)
    private func updateActivity(_ activity: Activity<LaunchActivityAttributes>, net: Date, status: String) async {
        let current = activity.content.state
        let changed = abs(current.net.timeIntervalSince(net)) > 1 || current.status != status
        guard changed else { return }
        let state = LaunchActivityAttributes.ContentState(net: net, status: status)
        await activity.update(ActivityContent(state: state, staleDate: net))
    }

    // MARK: Avisos ("Remind me 2 h before")

    private func remind(_ launch: SavedLaunch) async {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            settings = await center.notificationSettings()
        }
        let allowed: Set<UNAuthorizationStatus> = [.authorized, .provisional, .ephemeral]
        guard allowed.contains(settings.authorizationStatus) else {
            toast(Texts.isSpanish
                  ? "Activa las notificaciones de SatFleet Live en Ajustes para recibir el aviso."
                  : "Turn on notifications for SatFleet Live in Settings to get the reminder.")
            sendState()
            return
        }
        reminders[launch.id] = launch
        saveReminders()
        await scheduleNotification(launch)
        toast(Texts.isSpanish
              ? "Te avisaremos 2 horas antes del despegue."
              : "We'll remind you 2 hours before liftoff.")
        sendState()
    }

    private static func notificationId(_ launchId: String) -> String {
        "satfleet-launch-reminder-\(launchId)"
    }

    private func scheduleNotification(_ launch: SavedLaunch) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationId(launch.id)])

        let fireDate = launch.net.addingTimeInterval(-Self.reminderHours * 3600)
        let wait = fireDate.timeIntervalSinceNow
        guard wait > 30 else { return }   // ya es la hora: lo arranca la app al abrirse

        let content = UNMutableNotificationContent()
        if Texts.isSpanish {
            content.title = "Despegue en 2 horas: \(launch.rocket)"
            content.body = (launch.mission.isEmpty ? "" : "\(launch.mission). ")
                + "Toca para seguir la cuenta atrás en la pantalla de bloqueo."
        } else {
            content.title = "Liftoff in 2 hours: \(launch.rocket)"
            content.body = (launch.mission.isEmpty ? "" : "\(launch.mission). ")
                + "Tap to follow the countdown on your Lock Screen."
        }
        content.sound = .default
        content.userInfo = [
            "url": Self.launchesURL.absoluteString,
            "satfleetFollowLaunch": launch.id
        ]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
        let request = UNNotificationRequest(identifier: Self.notificationId(launch.id),
                                            content: content, trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            print("No se pudo programar el aviso: \(error.localizedDescription)")
        }
    }

    private func removeReminder(_ id: String) {
        guard reminders.removeValue(forKey: id) != nil else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationId(id)])
        saveReminders()
    }

    private func processPendingStart() {
        guard let id = pendingStartId else { return }
        pendingStartId = nil
        guard let launch = reminders[id] else { return }
        Task { await startFromSaved(launch) }
    }

    private func startFromSaved(_ launch: SavedLaunch) async {
        removeReminder(launch.id)
        guard #available(iOS 16.2, *), isSupported else { return }
        guard launch.net.timeIntervalSinceNow > -Self.lateStartLimit else { return }
        _ = await startActivity(launch)
        sendState()
    }

    // MARK: Puesta al dia (sin internet: lee lo que la web ya tiene guardado)

    private func syncFromWeb() {
        guard !isSyncing else { return }
        var ids = Set(reminders.keys)
        let following = followingId
        if !following.isEmpty { ids.insert(following) }
        guard !ids.isEmpty else { return }

        isSyncing = true
        guard let webView,
              let host = webView.url?.host?.lowercased(),
              host == "satfleetlive.com" || host.hasSuffix(".satfleetlive.com") else {
            Task { await housekeeping(fresh: [:]) }
            return
        }

        let idsData = (try? JSONSerialization.data(withJSONObject: Array(ids))) ?? Data("[]".utf8)
        let idsJSON = String(data: idsData, encoding: .utf8) ?? "[]"
        webView.evaluateJavaScript(Self.readCacheScript(idsJSON)) { [weak self] result, _ in
            let fresh = Self.parseCache(result as? String)
            Task { @MainActor in await self?.housekeeping(fresh: fresh) }
        }
    }

    private func housekeeping(fresh: [String: Fresh]) async {
        defer { isSyncing = false }
        let now = Date()

        // 1. Avisos: corregir la hora si ha cambiado y borrar los que ya pasaron
        for (id, saved) in reminders {
            var launch = saved
            if let f = fresh[id] {
                let moved = abs(f.net.timeIntervalSince(launch.net)) > 60
                launch.net = f.net
                launch.status = f.status
                reminders[id] = launch
                if moved { await scheduleNotification(launch) }
            }
            if launch.net.timeIntervalSince(now) < -Self.lateStartLimit {
                removeReminder(id)
            }
        }
        saveReminders()

        if #available(iOS 16.2, *) {
            // 2. La Live Activity en marcha: actualizar o quitar
            if let activity = currentActivity() {
                var net = activity.content.state.net
                var status = activity.content.state.status
                if let f = fresh[activity.attributes.launchId] {
                    net = f.net
                    status = f.status
                }
                if now.timeIntervalSince(net) > Self.endAfterLaunch {
                    await activity.end(nil, dismissalPolicy: .immediate)
                } else if status == "SUCCESS" || status == "FAILURE" {
                    let finalState = LaunchActivityAttributes.ContentState(net: net, status: status)
                    await activity.end(ActivityContent(state: finalState, staleDate: nil),
                                       dismissalPolicy: .after(now.addingTimeInterval(20 * 60)))
                } else {
                    await updateActivity(activity, net: net, status: status)
                }
            }

            // 3. Un aviso cuya hora ya llego y la app esta abierta: empieza la cuenta atras sola
            if isSupported, currentActivity() == nil,
               UIApplication.shared.applicationState == .active {
                let due = reminders.values
                    .filter {
                        let left = $0.net.timeIntervalSince(now)
                        return left <= Self.reminderHours * 3600 && left > -Self.lateStartLimit
                    }
                    .sorted { $0.net < $1.net }
                    .first
                if let due {
                    await startFromSaved(due)
                }
            }
        }

        sendState()
    }

    /// Lee de la web (localStorage) solo los lanzamientos que nos interesan
    private static func readCacheScript(_ idsJSON: String) -> String {
        """
        (function (ids) {
          try {
            var raw = localStorage.getItem('satfleet_launches_v1');
            if (!raw) { return null; }
            var cache = JSON.parse(raw);
            var out = {};
            (cache.results || []).forEach(function (l) {
              var id = String(l.id);
              if (ids.indexOf(id) < 0) { return; }
              out[id] = {
                net: l.net || '',
                status: (l.status && l.status.abbrev) || '',
                webcast: l.webcast_live === true
              };
            });
            return JSON.stringify(out);
          } catch (e) { return null; }
        })(\(idsJSON));
        """
    }

    private static func parseCache(_ text: String?) -> [String: Fresh] {
        guard let text, let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return [:]
        }
        var out: [String: Fresh] = [:]
        for (id, item) in dict {
            guard let netText = item["net"] as? String, let net = parseDate(netText) else { continue }
            let abbrev = item["status"] as? String ?? ""
            let webcast = item["webcast"] as? Bool ?? false
            out[id] = Fresh(net: net, status: statusLabel(abbrev, webcast: webcast))
        }
        return out
    }

    // MARK: Ayudantes

    /// Convierte el lanzamiento que manda la web en datos propios
    private static func parseLaunch(_ any: Any?) -> SavedLaunch? {
        guard let d = any as? [String: Any],
              let id = d["id"] as? String, !id.isEmpty,
              let netText = d["net"] as? String,
              let net = parseDate(netText) else { return nil }
        let rocket = clean(d["rocket"])
        return SavedLaunch(
            id: id,
            rocket: rocket.isEmpty ? (Texts.isSpanish ? "Cohete" : "Rocket") : rocket,
            mission: shortMission(clean(d["mission"])),
            pad: clean(d["pad"]),
            net: net,
            status: statusLabel(d["status"] as? String ?? "", webcast: d["webcast"] as? Bool ?? false)
        )
    }

    private static func clean(_ value: Any?) -> String {
        let text = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(60))
    }

    /// "Falcon 9 Block 5 | Starlink Group 10-12" -> "Starlink Group 10-12"
    private static func shortMission(_ name: String) -> String {
        if let range = name.range(of: " | ") {
            return String(name[range.upperBound...])
        }
        return name
    }

    /// Mismo criterio que las tarjetas de launches.html
    private static func statusLabel(_ abbrev: String, webcast: Bool) -> String {
        if webcast || abbrev == "In Flight" { return "LIVE" }
        switch abbrev {
        case "Go": return "GO"
        case "TBC": return "TBC"
        case "Hold": return "HOLD"
        case "Success": return "SUCCESS"
        case "Failure", "Partial Failure": return "FAILURE"
        default: return "TBD"
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }

    private static func loadReminders() -> [String: SavedLaunch] {
        guard let data = UserDefaults.standard.data(forKey: remindersKey),
              let saved = try? JSONDecoder().decode([String: SavedLaunch].self, from: data) else { return [:] }
        return saved
    }

    private func saveReminders() {
        if let data = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(data, forKey: Self.remindersKey)
        }
    }

    // MARK: Comunicacion con la web

    private func sendState() {
        let state: [String: Any] = [
            "supported": isSupported,
            "following": followingId,
            "reminders": Array(reminders.keys),
            "followWindowHours": Self.followWindowHours,
            "reminderHours": Self.reminderHours
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__satfleetLive && window.__satfleetLive.setState(\(json));",
                                    completionHandler: nil)
    }

    private func toast(_ message: String) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__satfleetLive && window.__satfleetLive.toast(\(text));",
                                    completionHandler: nil)
    }

    // MARK: Script que se mete en cada pagina
    //
    // Crea window.SatFleetLiveActivity, que es lo que usa launches.html para pintar
    // el boton. Fuera de la app de iOS no existe, y por eso en la web y en Android
    // no aparece nada.

    static let javascript = """
    (function () {
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.satfleetLive;
      if (!handler) { return; }
      var api = {
        state: { supported: false, following: '', reminders: [], followWindowHours: 7, reminderHours: 2 },
        follow: function (launch) { handler.postMessage({ action: 'follow', launch: launch }); },
        unfollow: function () { handler.postMessage({ action: 'unfollow' }); },
        remind: function (launch) { handler.postMessage({ action: 'remind', launch: launch }); },
        cancelReminder: function (id) { handler.postMessage({ action: 'cancelReminder', id: String(id) }); }
      };
      window.SatFleetLiveActivity = api;
      window.__satfleetLive = {
        setState: function (state) {
          if (state) { api.state = state; }
          try { document.dispatchEvent(new CustomEvent('satfleet-live-state', { detail: api.state })); } catch (e) {}
        },
        toast: function (message) {
          if (typeof window.showToast === 'function') { window.showToast(message); }
        }
      };
      handler.postMessage({ action: 'hello' });
    })();
    """
}
