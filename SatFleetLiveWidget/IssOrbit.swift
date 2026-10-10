//
//  IssOrbit.swift
//  SatFleet Live (iOS) - widget
//
//  Calcula donde esta la ISS a partir de sus datos orbitales (los de /api/tle/25544
//  de tu Worker). Es la traduccion exacta a Swift del IssOrbit.kt de la app de Android
//  (calculo SGP4, solo la parte para satelites "cercanos", que es el caso de la ISS).
//  No necesita internet ni librerias: el iPhone lo calcula solo.
//

import Foundation

/// Donde esta la ISS en un instante concreto.
struct IssPosition {
    let lat: Double        // grados, + norte / - sur
    let lng: Double        // grados, + este / - oeste
    let altKm: Double      // altura sobre el suelo, en km
    let speedKmh: Double   // velocidad, en km/h
}

struct IssOrbit {

    // MARK: Constantes (modelo WGS72, el que usa SGP4)

    private static let deg2rad = Double.pi / 180.0
    private static let twoPi = 2.0 * Double.pi
    private static let re = 6378.135
    private static let mu = 398600.8
    private static let xke = 60.0 / sqrt(re * re * re / mu)
    private static let j2 = 0.001082616
    private static let j3 = -0.00000253881
    private static let j4 = -0.00000165597
    private static let j3oj2 = j3 / j2
    private static let x2o3 = 2.0 / 3.0

    // MARK: Datos de la orbita (en radianes y minutos)

    private let epoch: Date
    private let ecco: Double
    private let argpo: Double
    private let inclo: Double
    private let mo: Double
    private let nodeo: Double
    private let bstar: Double

    // Valores preparados una sola vez
    private var no = 0.0
    private var isimp = false
    private var aycof = 0.0
    private var con41 = 0.0
    private var cc1 = 0.0
    private var cc4 = 0.0
    private var cc5 = 0.0
    private var d2 = 0.0
    private var d3 = 0.0
    private var d4 = 0.0
    private var delmo = 0.0
    private var eta = 0.0
    private var argpdot = 0.0
    private var omgcof = 0.0
    private var sinmao = 0.0
    private var t2cof = 0.0
    private var t3cof = 0.0
    private var t4cof = 0.0
    private var t5cof = 0.0
    private var x1mth2 = 0.0
    private var x7thm1 = 0.0
    private var mdot = 0.0
    private var nodedot = 0.0
    private var xlcof = 0.0
    private var xmcof = 0.0
    private var nodecf = 0.0

    /// false si los datos no sirven (valores raros o corruptos)
    private(set) var valid = false

    // MARK: Crear desde el JSON del Worker

    /// Acepta numeros o textos (Space-Track a veces manda los numeros como texto)
    init?(json o: [String: Any]) {
        func num(_ key: String) -> Double? {
            if let n = o[key] as? NSNumber { return n.doubleValue }
            if let s = o[key] as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        guard let epochText = o["EPOCH"] as? String,
              let epoch = IssOrbit.parseEpoch(epochText),
              let meanMotion = num("MEAN_MOTION"),
              let ecc = num("ECCENTRICITY"),
              let inc = num("INCLINATION"),
              let raan = num("RA_OF_ASC_NODE"),
              let argp = num("ARG_OF_PERICENTER"),
              let ma = num("MEAN_ANOMALY") else { return nil }
        self.init(epoch: epoch, meanMotion: meanMotion, eccentricity: ecc, inclinationDeg: inc,
                  raanDeg: raan, argPerigeeDeg: argp, meanAnomalyDeg: ma, bstar: num("BSTAR") ?? 0.0)
        if !valid { return nil }
    }

    init(epoch: Date, meanMotion: Double, eccentricity: Double, inclinationDeg: Double,
         raanDeg: Double, argPerigeeDeg: Double, meanAnomalyDeg: Double, bstar: Double) {
        let d2r = IssOrbit.deg2rad
        let twoPi = IssOrbit.twoPi
        let re = IssOrbit.re
        let xke = IssOrbit.xke
        let j2 = IssOrbit.j2
        let j4 = IssOrbit.j4
        let j3oj2 = IssOrbit.j3oj2
        let x2o3 = IssOrbit.x2o3

        self.epoch = epoch
        self.ecco = eccentricity
        self.argpo = argPerigeeDeg * d2r
        self.inclo = inclinationDeg * d2r
        self.mo = meanAnomalyDeg * d2r
        self.nodeo = raanDeg * d2r
        self.bstar = bstar

        var ok = true
        let noKozai = meanMotion * twoPi / 1440.0
        if !(noKozai > 0.0) || !(ecco >= 0.0 && ecco < 1.0) || !inclo.isFinite ||
            !bstar.isFinite || !mo.isFinite || !argpo.isFinite || !nodeo.isFinite {
            ok = false
        }
        // Esta version solo vale para orbitas de menos de 225 minutos (la ISS: ~92 min)
        if ok && (twoPi / noKozai) >= 225.0 { ok = false }

        if ok {
            // --- initl: quitar la perturbacion "kozai" del movimiento medio ---
            let eccsq = ecco * ecco
            let omeosq = 1.0 - eccsq
            let rteosq = sqrt(omeosq)
            let cosio = cos(inclo)
            let cosio2 = cosio * cosio

            let ak = pow(xke / noKozai, x2o3)
            let d1 = 0.75 * j2 * (3.0 * cosio2 - 1.0) / (rteosq * omeosq)
            var del = d1 / (ak * ak)
            let adel = ak * (1.0 - del * del - del * (1.0 / 3.0 + 134.0 * del * del / 81.0))
            del = d1 / (adel * adel)
            no = noKozai / (1.0 + del)

            let ao = pow(xke / no, x2o3)
            let sinio = sin(inclo)
            let po = ao * omeosq
            let con42 = 1.0 - 5.0 * cosio2
            con41 = -con42 - cosio2 - cosio2
            let posq = po * po
            let rp = ao * (1.0 - ecco)

            // --- sgp4init (parte de satelites cercanos) ---
            let ss = 78.0 / re + 1.0
            let qzms2t = pow((120.0 - 78.0) / re, 4)

            isimp = rp < (220.0 / re + 1.0)
            var sfour = ss
            var qzms24 = qzms2t
            let perige = (rp - 1.0) * re
            if perige < 156.0 {
                sfour = perige - 78.0
                if perige < 98.0 { sfour = 20.0 }
                qzms24 = pow((120.0 - sfour) / re, 4)
                sfour = sfour / re + 1.0
            }
            let pinvsq = 1.0 / posq
            let tsi = 1.0 / (ao - sfour)
            eta = ao * ecco * tsi
            let etasq = eta * eta
            let eeta = ecco * eta
            let psisq = abs(1.0 - etasq)
            let coef = qzms24 * pow(tsi, 4)
            let coef1 = coef / pow(psisq, 3.5)
            let cc2 = coef1 * no * (ao * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq)) +
                0.375 * j2 * tsi / psisq * con41 * (8.0 + 3.0 * etasq * (8.0 + etasq)))
            cc1 = bstar * cc2
            var cc3 = 0.0
            if ecco > 1.0e-4 { cc3 = -2.0 * coef * tsi * j3oj2 * no * sinio / ecco }
            x1mth2 = 1.0 - cosio2
            let cc4a = eta * (2.0 + 0.5 * etasq) + ecco * (0.5 + 2.0 * etasq)
            let cc4b = -3.0 * con41 * (1.0 - 2.0 * eeta + etasq * (1.5 - 0.5 * eeta))
            let cc4c = 0.75 * x1mth2 * (2.0 * etasq - eeta * (1.0 + etasq)) * cos(2.0 * argpo)
            cc4 = 2.0 * no * coef1 * ao * omeosq * (cc4a - j2 * tsi / (ao * psisq) * (cc4b + cc4c))
            cc5 = 2.0 * coef1 * ao * omeosq * (1.0 + 2.75 * (etasq + eeta) + eeta * etasq)
            let cosio4 = cosio2 * cosio2
            let temp1 = 1.5 * j2 * pinvsq * no
            let temp2 = 0.5 * temp1 * j2 * pinvsq
            let temp3 = -0.46875 * j4 * pinvsq * pinvsq * no
            mdot = no + 0.5 * temp1 * rteosq * con41 +
                0.0625 * temp2 * rteosq * (13.0 - 78.0 * cosio2 + 137.0 * cosio4)
            argpdot = -0.5 * temp1 * con42 +
                0.0625 * temp2 * (7.0 - 114.0 * cosio2 + 395.0 * cosio4) +
                temp3 * (3.0 - 36.0 * cosio2 + 49.0 * cosio4)
            let xhdot1 = -temp1 * cosio
            nodedot = xhdot1 + (0.5 * temp2 * (4.0 - 19.0 * cosio2) + 2.0 * temp3 * (3.0 - 7.0 * cosio2)) * cosio
            omgcof = bstar * cc3 * cos(argpo)
            xmcof = 0.0
            if ecco > 1.0e-4 { xmcof = -x2o3 * coef * bstar / eeta }
            nodecf = 3.5 * omeosq * xhdot1 * cc1
            t2cof = 1.5 * cc1
            let temp4 = 1.5e-12
            if abs(cosio + 1.0) > temp4 {
                xlcof = -0.25 * j3oj2 * sinio * (3.0 + 5.0 * cosio) / (1.0 + cosio)
            } else {
                xlcof = -0.25 * j3oj2 * sinio * (3.0 + 5.0 * cosio) / temp4
            }
            aycof = -0.5 * j3oj2 * sinio
            let delmotemp = 1.0 + eta * cos(mo)
            delmo = delmotemp * delmotemp * delmotemp
            sinmao = sin(mo)
            x7thm1 = 7.0 * cosio2 - 1.0

            if !isimp {
                let cc1sq = cc1 * cc1
                d2 = 4.0 * ao * tsi * cc1sq
                let temp = d2 * tsi * cc1 / 3.0
                d3 = (17.0 * ao + sfour) * temp
                d4 = 0.5 * temp * ao * tsi * (221.0 * ao + 31.0 * sfour) * cc1
                t3cof = d2 + 2.0 * cc1sq
                t4cof = 0.25 * (3.0 * d3 + cc1 * (12.0 * d2 + 10.0 * cc1sq))
                t5cof = 0.2 * (3.0 * d4 + 12.0 * cc1 * d3 + 6.0 * d2 * d2 + 15.0 * cc1sq * (2.0 * d2 + cc1sq))
            }
        }
        valid = ok
    }

    // MARK: Propagacion

    /// Posicion y velocidad en el sistema inercial (TEME) a `t` minutos de la epoca.
    /// Devuelve [x, y, z, vx, vy, vz] en km y km/s, o nil si no se puede calcular.
    private func propagateTeme(_ t: Double) -> [Double]? {
        guard valid else { return nil }
        let twoPi = IssOrbit.twoPi
        let xke = IssOrbit.xke
        let x2o3 = IssOrbit.x2o3
        let j2 = IssOrbit.j2

        // Actualizacion por gravedad y rozamiento con la atmosfera
        let xmdf = mo + mdot * t
        let argpdf = argpo + argpdot * t
        let nodedf = nodeo + nodedot * t
        var argpm = argpdf
        var mm = xmdf
        let t2 = t * t
        var nodem = nodedf + nodecf * t2
        var tempa = 1.0 - cc1 * t
        var tempe = bstar * cc4 * t
        var templ = t2cof * t2

        if !isimp {
            let delomg = omgcof * t
            let delmtemp = 1.0 + eta * cos(xmdf)
            let delm = xmcof * (delmtemp * delmtemp * delmtemp - delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * t
            let t4 = t3 * t
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
            tempe = tempe + bstar * cc5 * (sin(mm) - sinmao)
            templ = templ + t3cof * t3 + t4 * (t4cof + t * t5cof)
        }

        var nm = no
        var em = ecco
        let inclm = inclo
        guard nm > 0.0 else { return nil }

        let am = pow(xke / nm, x2o3) * tempa * tempa
        nm = xke / pow(am, 1.5)
        em -= tempe
        if em >= 1.0 || em < -0.001 { return nil }
        if em < 1.0e-6 { em = 1.0e-6 }
        mm += no * templ
        var xlm = mm + argpm + nodem
        nodem = nodem.truncatingRemainder(dividingBy: twoPi)
        argpm = argpm.truncatingRemainder(dividingBy: twoPi)
        xlm = xlm.truncatingRemainder(dividingBy: twoPi)
        mm = (xlm - argpm - nodem).truncatingRemainder(dividingBy: twoPi)

        let sinim = sin(inclm)
        let cosim = cos(inclm)
        let ep = em
        let xincp = inclm
        let argpp = argpm
        let omegap = nodem
        let mp = mm
        let sinip = sinim
        let cosip = cosim

        // Periodos largos
        let axnl = ep * cos(argpp)
        var temp = 1.0 / (am * (1.0 - ep * ep))
        let aynl = ep * sin(argpp) + temp * aycof
        let xl = mp + argpp + omegap + temp * xlcof * axnl

        // Ecuacion de Kepler
        let u = (xl - omegap).truncatingRemainder(dividingBy: twoPi)
        var eo1 = u
        var tem5 = 9999.9
        var ktr = 1
        var sineo1 = 0.0
        var coseo1 = 0.0
        while abs(tem5) >= 1.0e-12 && ktr <= 10 {
            sineo1 = sin(eo1)
            coseo1 = cos(eo1)
            tem5 = 1.0 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 { tem5 = tem5 > 0.0 ? 0.95 : -0.95 }
            eo1 += tem5
            ktr += 1
        }

        // Periodos cortos
        let ecose = axnl * coseo1 + aynl * sineo1
        let esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl
        let pl = am * (1.0 - el2)
        if pl < 0.0 { return nil }
        let rl = am * (1.0 - ecose)
        let rdotl = sqrt(am) * esine / rl
        let rvdotl = sqrt(pl) / rl
        let betal = sqrt(1.0 - el2)
        temp = esine / (1.0 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * temp)
        let cosu = am / rl * (coseo1 - axnl + aynl * temp)
        var su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu
        let cos2u = 1.0 - 2.0 * sinu * sinu
        temp = 1.0 / pl
        let temp1 = 0.5 * j2 * temp
        let temp2 = temp1 * temp

        let mrt = rl * (1.0 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u
        su -= 0.25 * temp2 * x7thm1 * sin2u
        let xnode = omegap + 1.5 * temp2 * cosip * sin2u
        let xinc = xincp + 1.5 * temp2 * cosip * sinip * cos2u
        let mvt = rdotl - nm * temp1 * x1mth2 * sin2u / xke
        let rvdot = rvdotl + nm * temp1 * (x1mth2 * cos2u + 1.5 * con41) / xke

        let sinsu = sin(su)
        let cossu = cos(su)
        let snod = sin(xnode)
        let cnod = cos(xnode)
        let sini = sin(xinc)
        let cosi = cos(xinc)
        let xmx = -snod * cosi
        let xmy = cnod * cosi
        let ux = xmx * sinsu + cnod * cossu
        let uy = xmy * sinsu + snod * cossu
        let uz = sini * sinsu
        let vx = xmx * cossu - cnod * sinsu
        let vy = xmy * cossu - snod * sinsu
        let vz = sini * cossu

        if mrt < 1.0 { return nil }   // el satelite ya habria caido a la Tierra

        let mr = mrt * IssOrbit.re
        let vkmpersec = IssOrbit.re * xke / 60.0
        let out = [
            mr * ux, mr * uy, mr * uz,
            (mvt * ux + rvdot * vx) * vkmpersec,
            (mvt * uy + rvdot * vy) * vkmpersec,
            (mvt * uz + rvdot * vz) * vkmpersec
        ]
        for v in out where !v.isFinite { return nil }
        return out
    }

    /// Posicion sobre la Tierra (latitud, longitud, altura, velocidad) en el instante dado.
    func position(at date: Date) -> IssPosition? {
        let tsince = date.timeIntervalSince(epoch) / 60.0
        guard let rv = propagateTeme(tsince) else { return nil }

        let twoPi = IssOrbit.twoPi
        let jd = date.timeIntervalSince1970 / 86400.0 + 2440587.5
        let gmst = IssOrbit.gmst(jd)
        let x = rv[0]
        let y = rv[1]
        let z = rv[2]

        // De coordenadas inerciales a latitud/longitud/altura (Tierra WGS84)
        let a = 6378.137
        let b = 6356.7523142
        let r = sqrt(x * x + y * y)
        let f = (a - b) / a
        let e2 = 2.0 * f - f * f

        var lng = atan2(y, x) - gmst
        while lng < -Double.pi { lng += twoPi }
        while lng > Double.pi { lng -= twoPi }

        var lat = atan2(z, r)
        var c = 1.0
        for _ in 0..<20 {
            let s = sin(lat)
            c = 1.0 / sqrt(1.0 - e2 * s * s)
            lat = atan2(z + a * c * e2 * s, r)
        }
        let height = r / cos(lat) - a * c

        let speed = sqrt(rv[3] * rv[3] + rv[4] * rv[4] + rv[5] * rv[5]) * 3600.0
        let latDeg = lat / IssOrbit.deg2rad
        let lngDeg = lng / IssOrbit.deg2rad
        guard latDeg.isFinite, lngDeg.isFinite, height.isFinite, height > 0.0 else { return nil }
        return IssPosition(lat: latDeg, lng: lngDeg, altKm: height, speedKmh: speed)
    }

    // MARK: Ayudantes

    /// Hora siderea de Greenwich (cuanto ha girado la Tierra), en radianes.
    private static func gmst(_ jdUt1: Double) -> Double {
        let tut1 = (jdUt1 - 2451545.0) / 36525.0
        var temp = -6.2e-6 * tut1 * tut1 * tut1 + 0.093104 * tut1 * tut1 +
            (876600.0 * 3600.0 + 8640184.812866) * tut1 + 67310.54841
        temp = (temp * deg2rad / 240.0).truncatingRemainder(dividingBy: twoPi)
        if temp < 0.0 { temp += twoPi }
        return temp
    }

    /// "2026-10-08T12:34:56.123456" (hora UTC) -> fecha
    static func parseEpoch(_ text: String) -> Date? {
        var clean = text.trimmingCharacters(in: .whitespaces)
        if clean.hasSuffix("Z") { clean.removeLast() }
        let parts = clean.split(separator: ".", maxSplits: 1)
        guard let main = parts.first else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let base = formatter.date(from: String(main)) else { return nil }
        var fraction = 0.0
        if parts.count > 1, let f = Double("0." + parts[1]) { fraction = f }
        return base.addingTimeInterval(fraction)
    }
}
