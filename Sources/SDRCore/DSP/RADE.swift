import Foundation
import Accelerate
import CRADE

/// The sideband a RADE signal is sent in.
public enum RADESideband: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Follow the FreeDV convention for the frequency.
    case auto = "Auto"
    case usb = "USB"
    case lsb = "LSB"

    public var id: String { rawValue }

    /// FreeDV uses the SSB conventions: LSB below 10 MHz, USB above, and USB on 60 m (5.25–5.45 MHz),
    /// where SSB is USB by regulation.
    public static func conventionallyLSB(at frequency: Double) -> Bool {
        frequency < 10_000_000 && !(5_250_000...5_450_000).contains(frequency)
    }

    public func isLSB(at frequency: Double) -> Bool {
        switch self {
        case .auto: return Self.conventionallyLSB(at: frequency)
        case .usb: return false
        case .lsb: return true
        }
    }
}

/// Receiver state of the FreeDV RADE decoder.
public struct RADEStatus: Equatable, Sendable {
    public var sync = false
    /// SNR in a 3 kHz noise bandwidth, valid while in sync.
    public var snrDB: Float = 0
    /// Offset of the received signal from where it should be (Hz), valid while in sync.
    public var frequencyOffset: Float = 0

    public init() {}
}

/// FreeDV RADE V1 receiver. Takes the channel as complex samples at the channel rate and returns decoded
/// speech at the same rate, so the rest of the audio chain is unchanged. An LSB signal is mirrored to the
/// orientation it has in USB before decoding.
///
/// The decoder works in modem frames of ~120 ms, each of which yields a burst of speech. A FIFO turns the
/// bursts into a steady stream: output starts once a frame and some margin are buffered, and falls back to
/// silence (refilling before it plays again) when the decoder loses the signal.
public final class RADEDecoder {
    /// Whether RADE was compiled in (needs the sources from scripts/fetch-rade.sh).
    public static let isAvailable = kymara_rade_available() != 0

    public let rate: Double
    public private(set) var status = RADEStatus()

    private let rade: OpaquePointer?
    private let modemRate = 8_000.0
    private let speechRate = 16_000.0
    private let inI: Resampler
    private let inQ: Resampler
    private let out: Resampler
    private var power: Float = 0
    private var speech: [Float] = []
    private var fifo: [Float] = []
    private var playing = false
    private let prefill: Int
    private let maxFill: Int

    public init(rate: Double) {
        self.rate = rate
        // The channel filter already limits the signal to the SSB passband, so the decimation filter only
        // has to keep aliases out of the 8 kHz modem band.
        inI = Resampler(inputRate: rate, outputRate: modemRate, passband: 3_000, stopband: 5_000)
        inQ = Resampler(inputRate: rate, outputRate: modemRate, passband: 3_000, stopband: 5_000)
        out = Resampler(inputRate: speechRate, outputRate: rate, passband: 7_000, stopband: 9_000)
        prefill = Int(0.18 * rate)
        maxFill = Int(0.5 * rate)
        rade = kymara_rade_open()
        let frame = rade.map { Int(kymara_rade_max_speech_per_frame($0)) } ?? 0
        speech = [Float](repeating: 0, count: max(frame, 1) * 2)
    }

    deinit {
        if let rade { kymara_rade_close(rade) }
    }

    /// Decodes `count` channel samples and writes `count` speech samples to `output`.
    public func process(re: UnsafePointer<Float>, im: UnsafePointer<Float>, count: Int, lsb: Bool = false,
                        output: UnsafeMutablePointer<Float>) {
        decode(re: re, im: im, count: count, lsb: lsb)

        if !playing && fifo.count >= prefill { playing = true }
        if fifo.count > maxFill { fifo.removeFirst(fifo.count - prefill) }
        if playing && fifo.count >= count {
            fifo.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: count) }
            fifo.removeFirst(count)
        } else {
            // Out of speech: play silence and buffer up again, so a resumed signal doesn't stutter.
            output.update(repeating: 0, count: count)
            if playing {
                let n = min(count, fifo.count)
                fifo.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: n) }
                fifo.removeFirst(n)
                playing = false
            }
        }
    }

    private func decode(re: UnsafePointer<Float>, im: UnsafePointer<Float>, count: Int, lsb: Bool) {
        guard let rade else { return }
        let n = inI.process(re, count: count)
        let m = inQ.process(im, count: count)
        assert(n == m)
        guard n > 0 else { return }
        var i = Array(inI.output[0..<n])
        var q = Array(inQ.output[0..<n])
        if lsb {
            // Conjugate: the signal below the dial frequency becomes the USB signal above it.
            q.inPlace { vDSP_vneg($0, 1, $0, 1, vDSP_Length(n)) }
        }
        normalise(&i, &q)

        var pos = 0
        while pos < n {
            var consumed: Int32 = 0
            let produced = i.withUnsafeBufferPointer { ip in
                q.withUnsafeBufferPointer { qp in
                    speech.withUnsafeMutableBufferPointer { sp in
                        kymara_rade_process(rade, ip.baseAddress! + pos, qp.baseAddress! + pos, Int32(n - pos), &consumed,
                                            sp.baseAddress!, Int32(sp.count))
                    }
                }
            }
            pos += Int(consumed)
            if produced > 0 {
                let k = speech.withUnsafeBufferPointer { out.process($0.baseAddress!, count: Int(produced)) }
                fifo.append(contentsOf: out.output[0..<k])
            }
        }
        status.sync = kymara_rade_sync(rade) != 0
        if status.sync {
            status.snrDB = kymara_rade_snr_db(rade)
            status.frequencyOffset = kymara_rade_frequency_offset(rade)
        }
    }

    /// Brings the modem input to about unit RMS (the level the decoder expects), tracking over ~1 s.
    private func normalise(_ i: inout [Float], _ q: inout [Float]) {
        let n = i.count
        var pi: Float = 0, pq: Float = 0
        vDSP_measqv(i, 1, &pi, vDSP_Length(n))
        vDSP_measqv(q, 1, &pq, vDSP_Length(n))
        let a = power == 0 ? 1 : 1 - Float(exp(-Double(n) / modemRate / 1.0))
        power += a * (pi + pq - power)
        var gain = 1 / max(power, 1e-12).squareRoot()
        i.inPlace { vDSP_vsmul($0, 1, &gain, $0, 1, vDSP_Length(n)) }
        q.inPlace { vDSP_vsmul($0, 1, &gain, $0, 1, vDSP_Length(n)) }
    }
}
