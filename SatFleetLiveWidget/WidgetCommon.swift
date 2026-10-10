//
//  WidgetCommon.swift
//  SatFleet Live (iOS) - widget
//
//  Colores de marca, textos (espanol / ingles segun el aparato) y pequenos
//  ayudantes que usan el widget de la ISS y la Live Activity.
//

import SwiftUI
import WidgetKit

// MARK: - Colores (los mismos que el widget de Android y la web)

enum Brand {
    static let ocean = Color(red: 11 / 255, green: 21 / 255, blue: 42 / 255)
    static let night = Color(red: 5 / 255, green: 8 / 255, blue: 15 / 255)
    static let purpleLight = Color(red: 192 / 255, green: 132 / 255, blue: 252 / 255)   // orbita en la web
    static let purple = Color(red: 139 / 255, green: 92 / 255, blue: 246 / 255)
    static let brandPurple = Color(red: 156 / 255, green: 39 / 255, blue: 176 / 255)    // --purple de la web
    static let card = Color(red: 15 / 255, green: 15 / 255, blue: 24 / 255)
    static let green = Color(red: 76 / 255, green: 217 / 255, blue: 100 / 255)
    static let orange = Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
    static let red = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)
}

// MARK: - Textos

enum WidgetTexts {
    static let isSpanish = Locale.preferredLanguages.first?.lowercased().hasPrefix("es") ?? false

    static let issName = isSpanish ? "ISS en directo" : "ISS live"
    static let issDescription = isSpanish
        ? "Dónde está ahora la Estación Espacial Internacional. Se mueve cada 5 minutos."
        : "Where the International Space Station is right now. Moves every 5 minutes."
    static let loading = isSpanish ? "Cargando datos de la ISS…" : "Loading ISS data…"
    static let willUpdate = isSpanish ? "Se actualizará en cuanto haya conexión" : "Will update once you are online"
    static let loadingShort = isSpanish ? "Cargando…" : "Loading…"
    static let outdated = isSpanish ? "datos antiguos" : "outdated data"
    static let west = isSpanish ? "O" : "W"

    static let liftoff = isSpanish ? "Despegue" : "Liftoff"
    static let checkStatus = isSpanish ? "Abre SatFleet Live para ver el estado" : "Open SatFleet Live for the latest status"
    static let success = isSpanish ? "Lanzamiento con éxito" : "Successful launch"
    static let failure = isSpanish ? "Lanzamiento fallido" : "Launch failed"
}

// MARK: - Formato de los datos de la ISS

enum IssFormat {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// EE. UU., Reino Unido, Liberia y Myanmar: millas (igual que en Android)
    static var imperial: Bool {
        let region = Locale.current.region?.identifier ?? ""
        return ["US", "GB", "LR", "MM"].contains(region)
    }

    private static func integer(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }

    /// "418 km  ·  27.600 km/h"
    static func altitudeAndSpeed(_ p: IssPosition) -> String {
        if imperial {
            return integer(p.altKm * 0.621371) + " mi  ·  " + integer(p.speedKmh * 0.621371) + " mph"
        }
        return integer(p.altKm) + " km  ·  " + integer(p.speedKmh) + " km/h"
    }

    static func altitude(_ p: IssPosition) -> String {
        imperial ? integer(p.altKm * 0.621371) + " mi" : integer(p.altKm) + " km"
    }

    /// "51.60° N  ·  23.40° O"
    static func coordinates(_ p: IssPosition, decimals: Int = 2) -> String {
        coord(p.lat, "N", "S", decimals) + "  ·  " + coord(p.lng, "E", WidgetTexts.west, decimals)
    }

    private static func coord(_ v: Double, _ pos: String, _ neg: String, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: posix, abs(v)) + "° " + (v >= 0 ? pos : neg)
    }
}

// MARK: - Icono del cohete (SVG propio en Assets, sin emojis)

struct RocketIcon: View {
    var size: CGFloat = 18
    var body: some View {
        Image("RocketIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Compatibilidad con iOS 17 y posteriores

extension View {
    /// iOS 17 exige declarar el fondo del widget con containerBackground
    @ViewBuilder
    func widgetBackground<Background: View>(_ background: Background) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { background }
        } else {
            self.background(background)
        }
    }
}

extension WidgetConfiguration {
    /// En iOS 17 el sistema anade margenes; el mapa queda mejor de borde a borde
    func disableContentMarginsIfAvailable() -> some WidgetConfiguration {
        if #available(iOS 17.0, *) {
            return self.contentMarginsDisabled()
        } else {
            return self
        }
    }
}
