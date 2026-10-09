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
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in _ = GIDSignIn.sharedInstance.handle(url) }
        }
    }
}
