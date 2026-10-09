//
//  LocationBridge.swift
//  SatFleet Live (iOS)
//
//  Hace que la web pida la ubicacion a la app (con el GPS del aparato)
//  en vez de a Safari. Asi solo sale UN permiso de ubicacion, el de iOS,
//  en lugar de dos (el de la app y el de la web).
//
//  Como funciona: al cargar cada pagina se mete un pequeno script que sustituye
//  navigator.geolocation por una version que manda los pedidos a la app.
//  La app consigue la posicion y se la devuelve a la web.
//

import Foundation
import CoreLocation
import WebKit

@MainActor
final class LocationBridge: NSObject, WKScriptMessageHandler {

    static let handlerName = "satfleetLocation"

    private let manager = CLLocationManager()
    private weak var webView: WKWebView?
    private var pendingIds: [Int] = []      // pedidos de "dame la posicion una vez"
    private var watchIds: Set<Int> = []     // pedidos de "avisame cada vez que me mueva"
    private var lastLocation: CLLocation?
    private var isUpdating = false

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Se llama al cambiar de pagina: olvida los pedidos de la pagina anterior.
    func reset() {
        pendingIds.removeAll()
        watchIds.removeAll()
        stopIfIdle()
    }

    // MARK: - Pedidos que llegan de la web

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let id = (body["id"] as? NSNumber)?.intValue else { return }

        if (body["highAccuracy"] as? Bool) == true {
            manager.desiredAccuracy = kCLLocationAccuracyBest
        }

        switch action {
        case "get":
            if let loc = recentLocation() {
                sendSuccess(id: id, location: loc)
            } else {
                pendingIds.append(id)
                startIfPossible()
            }
        case "watch":
            watchIds.insert(id)
            if let loc = recentLocation() {
                sendSuccess(id: id, location: loc)
            }
            startIfPossible()
        case "clear":
            watchIds.remove(id)
            stopIfIdle()
        default:
            break
        }
    }

    // MARK: - GPS

    private var isAuthorized: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// Ultima posicion conocida si tiene menos de 30 segundos.
    private func recentLocation() -> CLLocation? {
        guard isAuthorized, let loc = lastLocation, -loc.timestamp.timeIntervalSinceNow < 30 else { return nil }
        return loc
    }

    private func startIfPossible() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()      // el UNICO aviso de permiso
        case .authorizedWhenInUse, .authorizedAlways:
            if !isUpdating {
                isUpdating = true
                manager.startUpdatingLocation()
            }
        default:
            failAll(code: 1, message: "User denied Geolocation")
        }
    }

    private func stopIfIdle() {
        if pendingIds.isEmpty && watchIds.isEmpty && isUpdating {
            isUpdating = false
            manager.stopUpdatingLocation()
        }
    }

    private func failAll(code: Int, message: String) {
        let ids = pendingIds + Array(watchIds)
        pendingIds.removeAll()
        watchIds.removeAll()
        for id in ids {
            sendError(id: id, code: code, message: message)
        }
        stopIfIdle()
    }

    fileprivate func handleAuthorizationChange() {
        if isAuthorized {
            if !pendingIds.isEmpty || !watchIds.isEmpty {
                startIfPossible()
            }
        } else if manager.authorizationStatus != .notDetermined {
            failAll(code: 1, message: "User denied Geolocation")
        }
    }

    fileprivate func handleLocations(_ locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastLocation = loc
        let once = pendingIds
        pendingIds.removeAll()
        for id in once {
            sendSuccess(id: id, location: loc)
        }
        for id in watchIds {
            sendSuccess(id: id, location: loc)
        }
        stopIfIdle()
    }

    fileprivate func handleError(_ error: Error) {
        if let clError = error as? CLError {
            if clError.code == .locationUnknown { return }    // aun no hay senal: sigue intentandolo
            if clError.code == .denied {
                failAll(code: 1, message: "User denied Geolocation")
                return
            }
        }
        let once = pendingIds
        pendingIds.removeAll()
        for id in once {
            sendError(id: id, code: 2, message: "Position unavailable")
        }
        stopIfIdle()
    }

    // MARK: - Respuestas a la web

    private func valueOrNull(_ value: Double, valid: Bool) -> Any {
        if valid {
            return value
        }
        return NSNull()
    }

    private func sendSuccess(id: Int, location loc: CLLocation) {
        let payload: [String: Any] = [
            "lat": loc.coordinate.latitude,
            "lon": loc.coordinate.longitude,
            "acc": loc.horizontalAccuracy,
            "alt": valueOrNull(loc.altitude, valid: loc.verticalAccuracy >= 0),
            "altAcc": valueOrNull(loc.verticalAccuracy, valid: loc.verticalAccuracy >= 0),
            "heading": valueOrNull(loc.course, valid: loc.course >= 0),
            "speed": valueOrNull(loc.speed, valid: loc.speed >= 0),
            "ts": loc.timestamp.timeIntervalSince1970 * 1000
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__satfleetLocation && window.__satfleetLocation.success(\(id), \(json));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func sendError(id: Int, code: Int, message: String) {
        let safe = message.replacingOccurrences(of: "'", with: "")
        let js = "window.__satfleetLocation && window.__satfleetLocation.error(\(id), \(code), '\(safe)');"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Script que se mete en cada pagina

    static let javascript = """
    (function () {
      var handlers = window.webkit && window.webkit.messageHandlers;
      if (!handlers || !handlers.satfleetLocation) { return; }
      var bridge = handlers.satfleetLocation;
      var nextId = 1;
      var callbacks = {};

      function makeError(code, message) {
        return { code: code, message: message, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 };
      }

      function finish(id, cb) {
        if (!cb.watch) {
          delete callbacks[id];
          if (cb.timer) { clearTimeout(cb.timer); }
        }
      }

      window.__satfleetLocation = {
        success: function (id, p) {
          var cb = callbacks[id];
          if (!cb) { return; }
          finish(id, cb);
          var position = {
            coords: {
              latitude: p.lat, longitude: p.lon, accuracy: p.acc,
              altitude: p.alt, altitudeAccuracy: p.altAcc,
              heading: p.heading, speed: p.speed
            },
            timestamp: p.ts
          };
          try { cb.success(position); } catch (e) { console.error(e); }
        },
        error: function (id, code, message) {
          var cb = callbacks[id];
          if (!cb) { return; }
          finish(id, cb);
          if (typeof cb.error === 'function') {
            try { cb.error(makeError(code, message)); } catch (e) { console.error(e); }
          }
        }
      };

      function register(success, error, options, watch) {
        var id = nextId++;
        var cb = { success: success, error: error, watch: watch };
        callbacks[id] = cb;
        var timeout = (options && typeof options.timeout === 'number') ? options.timeout : Infinity;
        if (!watch && isFinite(timeout)) {
          cb.timer = setTimeout(function () {
            if (callbacks[id]) { window.__satfleetLocation.error(id, 3, 'Timeout expired'); }
          }, Math.max(timeout, 15000));
        }
        bridge.postMessage({ action: watch ? 'watch' : 'get', id: id, highAccuracy: !!(options && options.enableHighAccuracy) });
        return id;
      }

      var geolocation = {
        getCurrentPosition: function (success, error, options) { register(success, error, options, false); },
        watchPosition: function (success, error, options) { return register(success, error, options, true); },
        clearWatch: function (id) {
          var cb = callbacks[id];
          if (cb && cb.watch) {
            delete callbacks[id];
            bridge.postMessage({ action: 'clear', id: id });
          }
        }
      };

      try {
        Object.defineProperty(Navigator.prototype, 'geolocation', {
          configurable: true,
          get: function () { return geolocation; }
        });
      } catch (e) {
        try { Object.defineProperty(navigator, 'geolocation', { configurable: true, value: geolocation }); } catch (e2) {}
      }
    })();
    """
}

// MARK: - Avisos del GPS (llegan del sistema y se pasan al hilo principal)

extension LocationBridge: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.handleAuthorizationChange() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.handleLocations(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.handleError(error) }
    }
}