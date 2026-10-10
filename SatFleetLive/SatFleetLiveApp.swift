//
//  SatFleetLiveApp.swift
//  SatFleet Live (iOS)
//
//  Punto de arranque de la app. Solo abre la pantalla principal (ContentView)
//  en modo oscuro, para que la barra de arriba (hora, bateria) se vea en blanco.
//

import SwiftUI
import GoogleSignIn

@main
struct SatFleetLiveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    if url.scheme == "satfleetlive" {
                        LiveActivityManager.shared.handleDeepLink(url)   // toque en la Live Activity
                    } else {
                        _ = GIDSignIn.sharedInstance.handle(url)
                    }
                }
        }
    }
}
