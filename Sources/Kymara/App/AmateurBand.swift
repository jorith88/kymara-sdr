import Foundation
import SDRCore

/// Amateur HF and VHF bands (the widest allocation of the IARU regions), for band switching and the
/// "current band" filter. `home` and `mode` are where a band is first tuned before it has a band stack entry.
struct AmateurBand: Equatable, Identifiable, Sendable {
    var name: String
    var range: ClosedRange<Double>
    var home: Double
    var mode: DemodMode
    var id: String { name }

    static let all: [AmateurBand] = [
        .init(name: "160 m", range: 1_800_000...2_000_000, home: 1_850_000, mode: .lsb),
        .init(name: "80 m", range: 3_500_000...4_000_000, home: 3_700_000, mode: .lsb),
        .init(name: "60 m", range: 5_250_000...5_450_000, home: 5_360_000, mode: .usb),
        .init(name: "40 m", range: 7_000_000...7_300_000, home: 7_100_000, mode: .lsb),
        // No phone on 30 m: start on the FT8 dial frequency.
        .init(name: "30 m", range: 10_100_000...10_150_000, home: 10_136_000, mode: .usb),
        .init(name: "20 m", range: 14_000_000...14_350_000, home: 14_200_000, mode: .usb),
        .init(name: "17 m", range: 18_068_000...18_168_000, home: 18_130_000, mode: .usb),
        .init(name: "15 m", range: 21_000_000...21_450_000, home: 21_250_000, mode: .usb),
        .init(name: "12 m", range: 24_890_000...24_990_000, home: 24_950_000, mode: .usb),
        .init(name: "10 m", range: 28_000_000...29_700_000, home: 28_500_000, mode: .usb),
        .init(name: "6 m", range: 50_000_000...54_000_000, home: 50_150_000, mode: .usb),
        .init(name: "2 m", range: 144_000_000...148_000_000, home: 145_500_000, mode: .nfm),
        .init(name: "70 cm", range: 420_000_000...450_000_000, home: 433_500_000, mode: .nfm),
    ]

    static func containing(_ frequency: Double) -> AmateurBand? {
        all.first { $0.range.contains(frequency) }
    }

    /// The first band above `frequency`, skipping the band it is in.
    static func above(_ frequency: Double) -> AmateurBand? {
        all.first { $0.range.lowerBound > frequency }
    }

    /// The first band below `frequency`, skipping the band it is in.
    static func below(_ frequency: Double) -> AmateurBand? {
        all.last { $0.range.upperBound < frequency }
    }
}

/// A band stack entry: where the radio was last tuned on a band.
struct BandMemory: Codable, Equatable {
    var frequency: Double
    var mode: DemodMode
    var bandwidth: Double
}

extension BandMemory {
    /// Tolerant like `Bookmark`: only the frequency is required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try c.decode(Double.self, forKey: .frequency)
        mode = c.lenient(DemodMode.self, .mode) ?? DXSpot.sidebandConvention(frequency)
        bandwidth = c.lenient(Double.self, .bandwidth) ?? mode.defaultBandwidth
    }
}
