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

    var category: DXSpotCategory {
        if Self.isDigital(reported: reportedMode, frequency: frequency, comment: comment) { return .digital }
        return demodMode == .cw ? .cw : .phone
    }

    private static let digitalModes: Set<String> = ["DIGITAL", "DIGI", "FT8", "FT4", "JS8", "RTTY", "PSK", "PSK31"]

    /// Standard FT8 and FT4 dial frequencies in kHz, 160 m to 6 m.
    private static let digitalDials: [Double] = [
        1_840, 3_573, 3_575, 5_357, 7_047.5, 7_074, 10_136, 10_140, 14_074, 14_080,
        18_100, 18_104, 21_074, 21_140, 24_915, 24_919, 28_074, 28_180, 50_313, 50_318,
    ]

    /// A digital-mode spot: reported as one, named in the comment ("RTTY", "FT8", …), or within the
    /// audio passband above a standard FT8/FT4 dial frequency. A reported LSB or USB doesn't rule
    /// that out: DXHeat appears to derive it from the band plan, so it says LSB for RTTY on 40 m.
    /// A reported CW does, and so does "CW" or "SSB" in the comment.
    static func isDigital(reported: String?, frequency: Double, comment: String) -> Bool {
        let reported = reported?.uppercased() ?? ""
        if digitalModes.contains(reported) { return true }
        guard ["", "LSB", "USB"].contains(reported) else { return false }
        let words = commentWords(comment)
        if words.contains("CW") || words.contains("SSB") { return false }
        if words.contains(where: { digitalModes.contains(String($0)) }) { return true }
        let kHz = frequency / 1_000
        return digitalDials.contains { (0...3.5).contains(kHz - $0) }
    }

    private static func commentWords(_ comment: String) -> Set<Substring> {
        Set(comment.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
    }

    /// Digital modes (FT8, RTTY, PSK, …) are all received in USB, whatever the band. Without a
    /// reported mode, the comment ("CW", "FM"), the FT8/FT4 frequencies or else the sideband
    /// convention decides.
    static func demodMode(reported: String?, frequency: Double, comment: String) -> DemodMode {
        if isDigital(reported: reported, frequency: frequency, comment: comment) { return .usb }
        switch reported?.uppercased() {
        case "CW": return .cw
        case "USB": return .usb
        case "LSB": return .lsb
        case "AM": return .am
        case "FM": return .nfm
        default:
            let words = commentWords(comment)
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

enum DXSpotCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case cw = "CW"
    case phone = "Phone"
    case digital = "Digital"
    var id: String { rawValue }
}
