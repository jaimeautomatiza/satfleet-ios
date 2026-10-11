//
//  ReviewManager.swift
//  SatFleet Live (iOS)
//
//  Pide una valoracion con la ventana oficial de Apple, con las mismas reglas
//  que la app de Android (RatingManager.kt):
//    - despues de 5 aperturas de la app,
//    - y de 10 minutos de uso en total,
//    - como mucho una vez cada 180 dias.
//  Ademas, Apple limita la ventana a 3 veces al año y decide si la muestra.
//  En TestFlight la ventana NUNCA aparece: solo funciona con la app publicada.
//

import Foundation
import UIKit
import StoreKit

@MainActor
final class ReviewManager: NSObject {

    static let shared = ReviewManager()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let launches = "rating_launch_count"
        static let usageSeconds = "rating_total_usage_seconds"
        static let lastPrompt = "rating_last_prompt_time"
    }

    // Las mismas reglas que Android
    private let minLaunches = 5
    private let minUsageSeconds: TimeInterval = 10 * 60
    private let daysBetweenPrompts: Double = 180

    private var sessionStart: Date?
    private var triedThisSession = false

    /// Lo llama AppDelegate al abrir la app: cuenta una apertura y empieza a medir el uso
    func start() {
        defaults.set(defaults.integer(forKey: Key.launches) + 1, forKey: Key.launches)
        sessionStart = Date()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didBecomeActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(willResignActive),
                           name: UIApplication.willResignActiveNotification, object: nil)
    }

    @objc private func didBecomeActive() {
        if sessionStart == nil {
            sessionStart = Date()
        }
    }

    @objc private func willResignActive() {
        // Suma el tiempo de esta sesion al total
        if let start = sessionStart {
            let total = defaults.double(forKey: Key.usageSeconds) + Date().timeIntervalSince(start)
            defaults.set(total, forKey: Key.usageSeconds)
        }
        sessionStart = nil
        triedThisSession = false
    }

    /// Lo llama WebViewStore cada vez que termina de cargar una pagina
    func pageDidFinish() {
        guard !triedThisSession, shouldAsk() else { return }
        triedThisSession = true

        Task { @MainActor in
            // Esperamos un poco para no interrumpir mientras carga el mapa
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard UIApplication.shared.applicationState == .active,
                  let scene = UIApplication.shared.connectedScenes
                      .compactMap({ $0 as? UIWindowScene })
                      .first(where: { $0.activationState == .foregroundActive }) else { return }
            AppStore.requestReview(in: scene)
            self.defaults.set(Date().timeIntervalSince1970, forKey: Key.lastPrompt)
        }
    }

    private func shouldAsk() -> Bool {
        guard defaults.integer(forKey: Key.launches) >= minLaunches else { return false }

        var usage = defaults.double(forKey: Key.usageSeconds)
        if let start = sessionStart {
            usage += Date().timeIntervalSince(start)
        }
        guard usage >= minUsageSeconds else { return false }

        let last = defaults.double(forKey: Key.lastPrompt)
        if last > 0, Date().timeIntervalSince1970 - last < daysBetweenPrompts * 86_400 {
            return false
        }
        return true
    }
}