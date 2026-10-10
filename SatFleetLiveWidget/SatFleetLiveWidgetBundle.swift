//
//  SatFleetLiveWidgetBundle.swift
//  SatFleet Live (iOS) - widget
//
//  Punto de arranque de la extension. Junta las dos cosas que ofrece:
//  - El widget de la ISS (pantalla de inicio y pantalla de bloqueo)
//  - La Live Activity de lanzamientos (solo iPhone con iOS 16.1 o posterior)
//

import WidgetKit
import SwiftUI

@main
struct SatFleetLiveWidgetBundle: WidgetBundle {
    var body: some Widget {
        IssWidget()
        if #available(iOS 16.1, *) {
            LaunchLiveActivity()
        }
    }
}
