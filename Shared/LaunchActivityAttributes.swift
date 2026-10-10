//
//  LaunchActivityAttributes.swift
//  SatFleet Live (iOS) - compartido entre la app y el widget
//
//  Que datos lleva la Live Activity de un lanzamiento.
//  - Lo fijo (no cambia): cohete, mision, rampa e id del lanzamiento.
//  - Lo que puede cambiar (ContentState): la hora prevista y el estado (GO, TBC...).
//  La cuenta atras NO se guarda: la calcula el propio iPhone a partir de la hora.
//

import Foundation
import ActivityKit

@available(iOS 16.1, *)
struct LaunchActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        /// Hora prevista del despegue
        var net: Date
        /// "GO", "TBC", "TBD", "HOLD", "LIVE", "SUCCESS" o "FAILURE"
        var status: String
    }

    var launchId: String
    var rocket: String
    var mission: String
    var pad: String
}
