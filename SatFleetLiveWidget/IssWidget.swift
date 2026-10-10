//
//  IssWidget.swift
//  SatFleet Live (iOS) - widget
//
//  Widget de la ISS: mapamundi con la posicion de la Estacion Espacial, su
//  trayectoria (45 min atras en discontinua y 90 min adelante) y sus datos.
//
//  Como funciona (y por que gasta tan poco):
//  - Descarga la orbita de la ISS (/api/tle/25544 de tu Worker) COMO MUCHO
//    una vez cada 12 horas. Si falla, reintenta como mucho una vez por hora.
//  - Con esos datos el propio iPhone calcula donde esta la ISS (IssOrbit.swift).
//  - Cada 6 horas prepara de golpe los "dibujos" de las 6 horas siguientes,
//    uno cada 5 minutos. Asi la ISS se mueve en el mapa cada 5 minutos sin internet.
//  - Si nadie pone el widget, iOS nunca ejecuta este codigo: cero llamadas.
//  - Al tocarlo se abre la app tal cual estaba (no recarga nada).
//
//  Tamanos: pequeno (mapa centrado en la ISS), mediano (mapamundi, como Android)
//  y pantalla de bloqueo (texto). En iPad: pequeno y mediano.
//

import WidgetKit
import SwiftUI

// MARK: - Datos guardados (solo los usa el widget)

enum OrbitStore {
    static let url = URL(string: "https://worker.satfleetlive.com/api/tle/25544")!
    static let downloadEvery: TimeInterval = 12 * 3600       // datos nuevos como mucho cada 12 h
    static let retryAfterFail: TimeInterval = 3600           // si falla, esperar 1 h
    static let outdatedAfter: TimeInterval = 14 * 24 * 3600  // a partir de 14 dias avisamos

    private static let keyJson = "iss_orbit_json"
    private static let keyLastOk = "iss_last_download"
    private static let keyLastTry = "iss_last_attempt"
    private static var defaults: UserDefaults { .standard }

    static func load() -> IssOrbit? {
        guard let data = defaults.data(forKey: keyJson),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return IssOrbit(json: obj)
    }

    static var lastDownload: Date? {
        let t = defaults.double(forKey: keyLastOk)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func shouldDownload(now: Date = Date()) -> Bool {
        let lastOk = defaults.double(forKey: keyLastOk)
        let lastTry = defaults.double(forKey: keyLastTry)
        let hasData = defaults.data(forKey: keyJson) != nil
        let t = now.timeIntervalSince1970
        if hasData && t - lastOk < downloadEvery { return false }   // datos frescos
        if t - lastTry < retryAfterFail { return false }            // acabamos de intentarlo
        return true
    }

    /// Descarga la orbita. Llama a `completion` siempre (haya ido bien o mal).
    static func download(completion: @escaping () -> Void) {
        defaults.set(Date().timeIntervalSince1970, forKey: keyLastTry)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { completion() }
            guard let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { return }
            let obj: [String: Any]? = (parsed as? [[String: Any]])?.first ?? (parsed as? [String: Any])
            // Comprobar que los datos sirven antes de guardarlos
            guard let obj,
                  let orbit = IssOrbit(json: obj),
                  orbit.position(at: Date()) != nil,
                  let raw = try? JSONSerialization.data(withJSONObject: obj) else { return }
            defaults.set(raw, forKey: keyJson)
            defaults.set(Date().timeIntervalSince1970, forKey: keyLastOk)
        }.resume()
    }
}

// MARK: - Cada "dibujo" del widget

struct GeoPoint {
    let lat: Double
    let lng: Double
}

struct IssEntry: TimelineEntry {
    let date: Date
    let position: IssPosition?
    let past: [GeoPoint]
    let future: [GeoPoint]
    let outdated: Bool

    static func make(orbit: IssOrbit?, at date: Date, outdated: Bool) -> IssEntry {
        guard let orbit, let pos = orbit.position(at: date) else {
            return IssEntry(date: date, position: nil, past: [], future: [], outdated: false)
        }
        func track(_ from: Int, _ to: Int) -> [GeoPoint] {
            (from...to).compactMap { minute in
                orbit.position(at: date.addingTimeInterval(Double(minute) * 60)).map {
                    GeoPoint(lat: $0.lat, lng: $0.lng)
                }
            }
        }
        return IssEntry(date: date, position: pos, past: track(-45, 0), future: track(0, 90), outdated: outdated)
    }

    /// Orbita de ejemplo, SOLO para la vista previa de la galeria de widgets
    static var sample: IssEntry {
        let epoch = IssOrbit.parseEpoch("2026-10-01T12:00:00") ?? Date()
        let orbit = IssOrbit(epoch: epoch, meanMotion: 15.4976, eccentricity: 0.0006, inclinationDeg: 51.63,
                             raanDeg: 120, argPerigeeDeg: 80, meanAnomalyDeg: 280, bstar: 0)
        return make(orbit: orbit, at: epoch.addingTimeInterval(25 * 60), outdated: false)
    }
}

// MARK: - Proveedor: decide que se dibuja y cuando

struct IssProvider: TimelineProvider {
    private static let step: TimeInterval = 5 * 60       // un dibujo cada 5 minutos
    private static let span: TimeInterval = 6 * 3600     // preparamos 6 horas de golpe

    func placeholder(in context: Context) -> IssEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (IssEntry) -> Void) {
        if context.isPreview {
            completion(.sample)
            return
        }
        let orbit = OrbitStore.load()
        completion(orbit == nil ? .sample : IssEntry.make(orbit: orbit, at: Date(), outdated: isOutdated(Date())))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IssEntry>) -> Void) {
        let build = {
            let now = Date()
            guard let orbit = OrbitStore.load() else {
                // Sin datos todavia (sin conexion): volvemos a intentarlo en 1 hora
                let entry = IssEntry.make(orbit: nil, at: now, outdated: false)
                completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(3600))))
                return
            }
            let count = Int(Self.span / Self.step)
            let entries = (0...count).map { i -> IssEntry in
                let date = now.addingTimeInterval(Double(i) * Self.step)
                return IssEntry.make(orbit: orbit, at: date, outdated: isOutdated(date))
            }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.span))))
        }
        if OrbitStore.shouldDownload() {
            OrbitStore.download { build() }
        } else {
            build()
        }
    }

    private func isOutdated(_ date: Date) -> Bool {
        guard let last = OrbitStore.lastDownload else { return false }
        return date.timeIntervalSince(last) > OrbitStore.outdatedAfter
    }
}

// MARK: - Proyeccion: de latitud/longitud a puntos de la pantalla

struct MapProjection {
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat          // puntos de pantalla por grado
    let centerLon: Double
    let centerLat: Double

    /// lonSpan: cuantos grados de longitud caben a lo ancho (360 = mundo entero)
    init(size: CGSize, lonSpan: Double, iss: IssPosition?, centerOnIss: Bool) {
        width = max(size.width, 1)
        height = max(size.height, 1)
        scale = width / CGFloat(lonSpan)
        centerLon = centerOnIss ? (iss?.lng ?? 0) : 0
        // En vertical se ve la franja que cabe, centrada en la ISS si hace falta
        let halfLatVisible = Double(height / (2 * scale))
        if halfLatVisible >= 90 {
            centerLat = 0
        } else {
            let limit = 90 - halfLatVisible
            centerLat = min(max(iss?.lat ?? 0, -limit), limit)
        }
    }

    private func wrap(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    func x(_ lon: Double) -> CGFloat { width / 2 + CGFloat(wrap(lon - centerLon)) * scale }
    func y(_ lat: Double) -> CGFloat { height / 2 - CGFloat(lat - centerLat) * scale }
    func point(_ lat: Double, _ lon: Double) -> CGPoint { CGPoint(x: x(lon), y: y(lat)) }

    var mapWidth: CGFloat { 360 * scale }
    var mapHeight: CGFloat { 180 * scale }

    /// El mapamundi se pinta 3 veces seguidas para que no haya huecos al dar la vuelta
    var mapCentersX: [CGFloat] {
        let c = width / 2 + CGFloat(wrap(-centerLon)) * scale
        return [c - mapWidth, c, c + mapWidth]
    }
}

struct TrackShape: Shape {
    let points: [GeoPoint]
    let projection: MapProjection

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var previousX: CGFloat?
        for g in points {
            let p = projection.point(g.lat, g.lng)
            // Si da la vuelta por el borde del mapa, empezamos un trazo nuevo
            if let px = previousX, abs(p.x - px) <= projection.width / 2 {
                path.addLine(to: p)
            } else {
                path.move(to: p)
            }
            previousX = p.x
        }
        return path
    }
}

// MARK: - Dibujo del mapa

struct IssMapLayer: View {
    let entry: IssEntry
    let small: Bool
    let size: CGSize

    var body: some View {
        let proj = MapProjection(size: size, lonSpan: small ? 120 : 360,
                                 iss: entry.position, centerOnIss: small)
        ZStack(alignment: .topLeading) {
            Brand.ocean

            ForEach(proj.mapCentersX, id: \.self) { centerX in
                Image("WorldMap")
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: proj.mapWidth, height: proj.mapHeight)
                    .position(x: centerX, y: proj.y(0))
            }

            if let pos = entry.position {
                TrackShape(points: entry.past, projection: proj)
                    .stroke(Brand.purpleLight.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [5, 4]))
                TrackShape(points: entry.future, projection: proj)
                    .stroke(Brand.purpleLight.opacity(0.95),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                let p = proj.point(pos.lat, pos.lng)
                Circle()
                    .fill(RadialGradient(colors: [Brand.purpleLight.opacity(0.5), Brand.purpleLight.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 16))
                    .frame(width: 32, height: 32)
                    .position(p)
                Circle()
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .position(p)
                Circle()
                    .stroke(Brand.purple, lineWidth: 2.2)
                    .frame(width: 13, height: 13)
                    .position(p)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

// MARK: - Widget de pantalla de inicio (pequeno y mediano)

struct IssHomeWidgetView: View {
    let entry: IssEntry
    let small: Bool

    var body: some View {
        ZStack {
            GeometryReader { geo in
                IssMapLayer(entry: entry, small: small, size: geo.size)
            }

            // Sombreado arriba y abajo para que se lea el texto
            VStack(spacing: 0) {
                LinearGradient(colors: [Brand.night.opacity(0.8), Brand.night.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 36)
                Spacer(minLength: 0)
                LinearGradient(colors: [Brand.night.opacity(0), Brand.night.opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: small ? 66 : 54)
            }

            // Textos
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(small ? "ISS" : "ISS · SatFleet Live")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.position != nil {
                        Group {
                            if entry.outdated {
                                Text(WidgetTexts.outdated)
                            } else {
                                Text(entry.date, style: .time)
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let pos = entry.position {
                    Text(IssFormat.altitudeAndSpeed(pos))
                        .font(.system(size: small ? 12 : 13, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(IssFormat.coordinates(pos))
                        .font(.system(size: small ? 10.5 : 11))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text(WidgetTexts.loading)
                        .font(.system(size: small ? 12 : 13, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(WidgetTexts.willUpdate)
                        .font(.system(size: small ? 10.5 : 11))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
        }
        .widgetBackground(Brand.ocean)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Widgets de pantalla de bloqueo (solo texto)

struct IssRectangularView: View {
    let entry: IssEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("ISS")
                .font(.headline)
                .widgetAccentable()
            if let pos = entry.position {
                Text(IssFormat.coordinates(pos, decimals: 1))
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(IssFormat.altitudeAndSpeed(pos))
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text(WidgetTexts.loadingShort)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetBackground(Color.clear)
    }
}

struct IssInlineView: View {
    let entry: IssEntry

    var body: some View {
        Group {
            if let pos = entry.position {
                Text("ISS " + IssFormat.coordinates(pos, decimals: 1))
            } else {
                Text("ISS · " + WidgetTexts.loadingShort)
            }
        }
        .widgetBackground(Color.clear)
    }
}

// MARK: - El widget

struct IssWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: IssEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            IssRectangularView(entry: entry)
        case .accessoryInline:
            IssInlineView(entry: entry)
        case .systemSmall:
            IssHomeWidgetView(entry: entry, small: true)
        default:
            IssHomeWidgetView(entry: entry, small: false)
        }
    }
}

struct IssWidget: Widget {
    let kind = "IssWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: IssProvider()) { entry in
            IssWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(WidgetTexts.issName)
        .description(WidgetTexts.issDescription)
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
        .disableContentMarginsIfAvailable()
    }
}
