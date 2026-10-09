//
//  ContentView.swift
//  SatFleet Live (iOS)
//
//  Pantalla principal: la web de SatFleet ocupando todo, y encima (cuando toca)
//  la pantalla de carga, la pantalla "Sin conexion" y el boton de recarga,
//  igual que en la app de Android.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = WebViewStore()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.satfleetBackground
                .ignoresSafeArea()

            WebView(store: store)

            if !store.hasLoadedOnce && !store.isOffline {
                LoadingView()
            }

            if store.isOffline {
                OfflineView { store.retry() }
            } else if store.hasLoadedOnce {
                ReloadButton { store.reload() }
                    .padding(12)
            }
        }
    }
}

// MARK: - Pantalla de carga (mientras abre la web la primera vez)

struct LoadingView: View {
    // Mismos colores que la pantalla de carga de Android
    private let lavender = Color(red: 167.0/255, green: 139.0/255, blue: 250.0/255)
    private let gradient = LinearGradient(
        colors: [
            Color(red: 15.0/255, green: 15.0/255, blue: 30.0/255),
            Color(red: 22.0/255, green: 33.0/255, blue: 62.0/255),
            Color(red: 26.0/255, green: 10.0/255, blue: 46.0/255)
        ],
        startPoint: .bottomTrailing,
        endPoint: .topLeading
    )

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 140, height: 140)
                .accessibilityHidden(true)
            Text("SatFleet Live")
                .font(.system(size: 28, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(Color.white)
                .padding(.top, 24)
            Text("Satellites, Rockets, Moon, Mars & Deep Space")
                .font(.system(size: 14))
                .foregroundStyle(lavender)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 24)
            ProgressView()
                .tint(lavender)
                .scaleEffect(1.2)
                .padding(.top, 32)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(gradient.ignoresSafeArea())
    }
}

// MARK: - Pantalla "Sin conexion"

struct OfflineView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 64))
                .foregroundStyle(Color.satfleetPurple)

            Text(Texts.offlineTitle)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.top, 24)

            Text(Texts.offlineMessage)
                .font(.system(size: 16))
                .foregroundStyle(Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .padding(.horizontal, 40)

            Button(action: onRetry) {
                Text(Texts.retry)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.satfleetPurple))
            }
            .padding(.top, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.satfleetBackground.ignoresSafeArea())
    }
}

// MARK: - Boton de recarga (abajo a la izquierda, como en Android)

struct ReloadButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color(white: 0.08).opacity(0.9)))
        }
        .accessibilityLabel(Texts.reload)
    }
}

// MARK: - Textos (en espanol si el aparato esta en espanol; si no, en ingles)

enum Texts {
    static let isSpanish = Locale.preferredLanguages.first?.lowercased().hasPrefix("es") ?? false

    static let offlineTitle = isSpanish ? "Sin conexión" : "No connection"
    static let offlineMessage = isSpanish
        ? "No se pudo cargar la página.\nVerifica tu conexión a Internet."
        : "The page could not be loaded.\nCheck your internet connection."
    static let retry = isSpanish ? "Reintentar" : "Retry"
    static let reload = isSpanish ? "Recargar página" : "Reload page"
    static let cancel = isSpanish ? "Cancelar" : "Cancel"
}
