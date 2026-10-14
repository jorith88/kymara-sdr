import Foundation
import SDRCore

/// The tuning and demodulation settings of one VFO. `RadioController`'s own properties hold the selected VFO;
/// the other one waits in a `VFOState`.
struct VFOState: Codable, Equatable {
    var frequency: Double = 100_000_000
    var mode: DemodMode = .wfm
    var bandwidth: Double = 180_000
    var step: Double = 100_000
    /// Last bandwidth and step per mode, by mode name.
    var bandwidths: [String: Double] = [:]
    var steps: [String: Double] = [:]
    var volume: Double = 0.5
    /// Not persisted (like VFO A's mute, the app starts unmuted).
    var muted = false
    var output: AudioRoute = .both
    var squelchEnabled = false
    var squelchLevel: Double = -50
    var squelchAuto = false
    var agcMode: AGCMode = .medium
    var afGain: Double = 20
    var autoNotch = false
    var radeSideband: RADESideband = .auto
    var stereo = true
    var rds = true

    /// Whether RADE reception on this VFO is in LSB.
    var radeLSB: Bool { mode.isRADE && radeSideband.isLSB(at: frequency) }
    var modeLabel: String { mode.isRADE ? mode.rawValue + " " + (radeLSB ? "LSB" : "USB") : mode.rawValue }
    var filterEdges: (lo: Double, hi: Double) { mode.filterEdges(bandwidth: bandwidth, lsb: radeLSB) }

    private enum CodingKeys: String, CodingKey {
        case frequency, mode, bandwidth, step, bandwidths, steps, volume, output, squelchEnabled, squelchLevel,
             squelchAuto, agcMode, afGain, autoNotch, radeSideband, stereo, rds
    }
}

extension VFOState {
    /// Tolerant like `RadioSettings`: a missing or unreadable field keeps its default.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = c.lenient(T.self, key) { value = v }
        }
        read(.frequency, &frequency)
        read(.mode, &mode)
        read(.bandwidth, &bandwidth)
        read(.step, &step)
        read(.bandwidths, &bandwidths)
        read(.steps, &steps)
        read(.volume, &volume)
        read(.output, &output)
        read(.squelchEnabled, &squelchEnabled)
        read(.squelchLevel, &squelchLevel)
        read(.squelchAuto, &squelchAuto)
        read(.agcMode, &agcMode)
        read(.afGain, &afGain)
        read(.autoNotch, &autoNotch)
        read(.radeSideband, &radeSideband)
        read(.stereo, &stereo)
        read(.rds, &rds)
    }
}

/// What the meter shows for one VFO; swapped along with `VFOState` when the selection changes.
struct VFOMeter: Equatable {
    var signalDB: Double = -150
    var signalPeakDB: Double = -150
    var squelchOpen = false
    var snrDB: Double?
    var stereoLocked = false
    var rds = RDSInfo()
    var rade: RADEStatus?
    var radeCallsign: String?
    var radeCallsignCount = 0
    var inBand = true
}
