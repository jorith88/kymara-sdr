import Foundation

/// SDRplay RSP hardware models, identified by the API's `hwVer`.
public enum SDRplayModel: Equatable, Sendable {
    case rsp1, rsp1a, rsp1b, rsp2, rspDuo, rspDx, rspDxR2
    case unknown(UInt8)

    public init(hwVer: UInt8) {
        switch hwVer {
        case 1: self = .rsp1
        case 255: self = .rsp1a
        case 6: self = .rsp1b
        case 2: self = .rsp2
        case 3: self = .rspDuo
        case 4: self = .rspDx
        case 7: self = .rspDxR2
        default: self = .unknown(hwVer)
        }
    }

    public var name: String {
        switch self {
        case .rsp1: return "RSP1"
        case .rsp1a: return "RSP1A"
        case .rsp1b: return "RSP1B"
        case .rsp2: return "RSP2"
        case .rspDuo: return "RSPduo"
        case .rspDx: return "RSPdx"
        case .rspDxR2: return "RSPdx-R2"
        case .unknown(let v): return "RSP (hw \(v))"
        }
    }

    public var hasBiasT: Bool {
        switch self {
        case .rsp1, .unknown: return false
        default: return true
        }
    }

    /// Antenna ports to choose from. For the RSPduo, A and B are the two tuners and Hi-Z is tuner 1's Hi-Z port.
    public var antennas: [SDRplayConfig.Antenna] {
        switch self {
        case .rsp2: return [.a, .b, .hiZ]
        case .rspDuo: return [.a, .b, .hiZ]
        case .rspDx, .rspDxR2: return [.a, .b, .c]
        default: return []
        }
    }

    public var hasRFNotch: Bool {
        switch self {
        case .rsp1a, .rsp1b, .rsp2, .rspDuo, .rspDx, .rspDxR2: return true
        default: return false
        }
    }

    public var hasDABNotch: Bool {
        switch self {
        case .rsp1a, .rsp1b, .rspDuo, .rspDx, .rspDxR2: return true
        default: return false
        }
    }

    /// The RSPduo's AM notch on tuner 1.
    public var hasAMNotch: Bool { self == .rspDuo }

    /// Number of LNA states (0 = most gain) at a frequency, from the gain reduction tables in the SDRplay API specification.
    public func lnaStateCount(frequency f: Double, antenna: SDRplayConfig.Antenna) -> Int {
        switch self {
        case .rsp1, .unknown:
            return 4
        case .rsp1a, .rsp1b:
            return f < 60e6 ? 7 : f < 1000e6 ? 10 : 9
        case .rsp2:
            if antenna == .hiZ && f < 60e6 { return 5 }
            return f < 420e6 ? 9 : 6
        case .rspDuo:
            if antenna == .hiZ && f < 60e6 { return 5 }
            return f < 60e6 ? 7 : f < 1000e6 ? 10 : 9
        case .rspDx, .rspDxR2:
            if f < 12e6 { return 19 }
            if f < 50e6 { return 20 }
            if f < 60e6 { return 25 }
            if f < 250e6 { return 27 }
            if f < 420e6 { return 28 }
            if f < 1000e6 { return 21 }
            return 19
        }
    }
}

public struct SDRplayDeviceInfo: Identifiable, Hashable, Sendable {
    public let serial: String
    public let hwVer: UInt8
    public var model: SDRplayModel { SDRplayModel(hwVer: hwVer) }
    public var id: String { serial }
    public var label: String { "SDRplay \(model.name) (SN \(serial))" }
}

/// SDRplay-specific receiver settings.
public struct SDRplayConfig: Codable, Equatable, Sendable {
    public enum IFMode: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Low IF where the sample rate allows it (no DC spike), otherwise zero IF.
        case auto
        case zeroIF
        case lowIF
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .auto: return "Auto"
            case .zeroIF: return "Zero IF"
            case .lowIF: return "Low IF"
            }
        }
    }

    public enum Antenna: String, Codable, CaseIterable, Identifiable, Sendable {
        case a, b, c, hiZ
        public var id: String { rawValue }
        public func label(for model: SDRplayModel) -> String {
            switch (model, self) {
            case (.rspDuo, .a): return "Tuner 1"
            case (.rspDuo, .b): return "Tuner 2"
            case (.rspDuo, .hiZ): return "T1 Hi-Z"
            case (_, .a): return "A"
            case (_, .b): return "B"
            case (_, .c): return "C"
            case (_, .hiZ): return "Hi-Z"
            }
        }
    }

    public static let ifGainReductionRange = 20...59

    /// 0 = most gain; the number of states depends on the model and frequency.
    public var lnaState = 0
    /// IF gain reduction in dB (20…59), used when the IF AGC is off.
    public var ifGainReduction = 40
    public var ifAGC = true
    public var ifMode = IFMode.auto
    public var antenna = Antenna.a
    public var rfNotch = false
    public var dabNotch = false
    public var amNotch = false

    public init() {}

    // Tolerant decoding: a missing or malformed field keeps its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ field: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { field = v }
        }
        read(.lnaState, &lnaState)
        read(.ifGainReduction, &ifGainReduction)
        read(.ifAGC, &ifAGC)
        read(.ifMode, &ifMode)
        read(.antenna, &antenna)
        read(.rfNotch, &rfNotch)
        read(.dabNotch, &dabNotch)
        read(.amNotch, &amNotch)
    }
}

/// How an output sample rate is produced: ADC rate, IF, IF filter and hardware decimation.
public struct SDRplayRatePlan: Equatable, Sendable {
    public let fsHz: Double
    public let ifKHz: Int32
    public let bwKHz: Int32
    public let decimation: Int

    public var isLowIF: Bool { ifKHz != 0 }

    public static let outputRates: [Double] = [250_000, 500_000, 1_000_000, 2_000_000, 2_048_000, 3_000_000,
                                               4_000_000, 5_000_000, 6_000_000, 7_000_000, 8_000_000, 10_000_000]

    public static func plan(outputRate rate: Double, ifMode: SDRplayConfig.IFMode) -> SDRplayRatePlan {
        if ifMode != .zeroIF {
            // 8.192 MHz with a 2.048 MHz IF gives 2.048 MS/s.
            if rate == 2_048_000 {
                return SDRplayRatePlan(fsHz: 8_192_000, ifKHz: 2048, bwKHz: 1536, decimation: 1)
            }
            // 6 MHz with a 1.62 MHz IF gives 2 MS/s, then hardware decimation.
            let dec = 2_000_000 / rate
            if dec >= 1, dec <= 32, dec == dec.rounded(), Int(dec).nonzeroBitCount == 1 {
                return SDRplayRatePlan(fsHz: 6_000_000, ifKHz: 1620, bwKHz: 1536, decimation: Int(dec))
            }
        }
        var dec = 1
        while rate * Double(dec) < 2_000_000, dec < 32 { dec *= 2 }
        return SDRplayRatePlan(fsHz: rate * Double(dec), ifKHz: 0, bwKHz: bandwidth(for: rate), decimation: dec)
    }

    /// Widest IF filter that does not exceed the output rate.
    static func bandwidth(for rate: Double) -> Int32 {
        switch rate {
        case ..<300_000: return 200
        case ..<600_000: return 300
        case ..<1_536_000: return 600
        case ..<5_000_000: return 1536
        case ..<6_000_000: return 5000
        case ..<7_000_000: return 6000
        case ..<8_000_000: return 7000
        default: return 8000
        }
    }
}
