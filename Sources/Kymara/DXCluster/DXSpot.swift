import Foundation
import SDRCore

/// One DX cluster spot, after merging duplicate reports of the same station on the same frequency.
struct DXSpot: Identifiable, Hashable, Sendable {
    var dxCall: String
    /// Hz.
    var frequency: Double
    /// Time of the most recent report (UTC, minute resolution).
    var time: Date
    /// Spotters, most recent first.
    var spotters: [String]
    var comment: String
    /// The mode as the cluster reported it ("CW", "USB", "DIGITAL", …), if any.
    var reportedMode: String?
    /// Continent of the DX station ("EU", "NA", …).
    var dxContinent: String
    var spotterContinent: String
    /// ISO country code of the DX station, lowercase ("jp").
    var countryCode: String
    var locator: String?

    /// Duplicates are reports of the same call within the same kHz.
    var id: String { Self.key(call: dxCall, frequency: frequency) }

    static func key(call: String, frequency: Double) -> String {
        "\(call.uppercased())@\(Int((frequency / 1_000).rounded()))"
    }

    /// The demodulator to tune this spot with.
    var demodMode: DemodMode { Self.demodMode(reported: reportedMode, frequency: frequency, comment: comment) }

    static func demodMode(reported: String?, frequency: Double, comment: String) -> DemodMode {
        switch reported?.uppercased() {
        case "CW": return .cw
        case "USB": return .usb
        case "LSB": return .lsb
        case "AM": return .am
        case "FM": return .nfm
        // FT8, RTTY, PSK and friends are all received in USB, whatever the band.
        case "DIGITAL", "DIGI", "FT8", "FT4", "RTTY", "PSK", "PSK31": return .usb
        default:
            let words = comment.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if words.contains("CW") { return .cw }
            if words.contains("FM") { return .nfm }
            return sidebandConvention(frequency)
        }
    }

    /// Amateur phone convention: LSB below 10 MHz, except on 60 m; USB elsewhere.
    static func sidebandConvention(_ frequency: Double) -> DemodMode {
        let sixtyMetres = 5_250_000.0...5_450_000.0
        return frequency < 10_000_000 && !sixtyMetres.contains(frequency) ? .lsb : .usb
    }

    /// Combines a newer report of the same spot into this one.
    mutating func merge(_ other: DXSpot) {
        let newer = other.time >= time
        for s in other.spotters where !spotters.contains(s) {
            if newer { spotters.insert(s, at: 0) } else { spotters.append(s) }
        }
        guard newer else { return }
        time = other.time
        frequency = other.frequency
        if !other.comment.isEmpty { comment = other.comment }
        if let m = other.reportedMode { reportedMode = m }
        if let l = other.locator { locator = l }
    }
}
