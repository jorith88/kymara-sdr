import Foundation
import Accelerate

public enum DemodMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case am = "AM"
    case nfm = "NFM"
    case wfm = "WFM"
    case usb = "USB"
    case lsb = "LSB"
    case cw = "CW"
    case dsb = "DSB"
    /// FreeDV RADE V1 digital voice (received in USB).
    case rade = "RADE"

    public var id: String { rawValue }

    /// The modes this build can receive (RADE needs the sources from scripts/fetch-rade.sh).
    public static var available: [DemodMode] {
        allCases.filter { $0 != .rade || RADEDecoder.isAvailable }
    }

    public var defaultBandwidth: Double {
        switch self {
        case .am: return 8_000
        case .nfm: return 12_500
        case .wfm: return 180_000
        case .usb, .lsb: return 2_700
        case .cw: return 500
        case .dsb: return 6_000
        case .rade: return 2_700
        }
    }

    public var bandwidthPresets: [Double] {
        switch self {
        case .am: return [3_000, 5_000, 6_000, 8_000, 10_000, 15_000]
        case .nfm: return [6_250, 8_330, 10_000, 12_500, 15_000, 25_000]
        case .wfm: return [80_000, 120_000, 150_000, 180_000, 200_000]
        case .usb, .lsb: return [1_800, 2_100, 2_400, 2_700, 3_000, 4_000]
        case .cw: return [100, 200, 300, 500, 800, 1_200]
        case .dsb: return [3_000, 4_000, 6_000, 8_000, 10_000]
        case .rade: return [2_400, 2_700, 3_000]
        }
    }

    public var bandwidthRange: ClosedRange<Double> {
        switch self {
        case .wfm: return 30_000...220_000
        case .cw: return 50...3_000
        case .usb, .lsb: return 500...6_000
        // The RADE V1 signal occupies about 0.8–2.3 kHz from the dial frequency.
        case .rade: return 2_400...3_000
        default: return 1_000...40_000
        }
    }

    public var defaultStep: Double {
        switch self {
        case .am: return 5_000
        case .nfm: return 12_500
        case .wfm: return 100_000
        case .usb, .lsb, .dsb: return 100
        case .rade: return 1_000
        case .cw: return 10
        }
    }

    /// Modes where a steady tone in the audio is interference (a carrier or heterodyne), not the signal.
    public var supportsAutoNotch: Bool {
        switch self {
        case .am, .usb, .lsb, .dsb: return true
        case .nfm, .wfm, .cw, .rade: return false
        }
    }

    /// Filter passband edges relative to the VFO in Hz. `lsb` selects the sideband for RADE.
    public func filterEdges(bandwidth bw: Double, lsb: Bool = false) -> (lo: Double, hi: Double) {
        switch self {
        case .rade: return lsb ? (-(100 + bw), -100) : (100, 100 + bw)
        case .usb: return (100, 100 + bw)
        case .lsb: return (-(100 + bw), -100)
        default: return (-bw / 2, bw / 2)
        }
    }
}

public enum AGCMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case off = "Off"
    case fast = "Fast"
    case medium = "Medium"
    case slow = "Slow"
    public var id: String { rawValue }
}

/// Quadrature FM discriminator: angle of z[n]·conj(z[n-1]).
public final class FMDemodulator {
    private var lastRe: Float = 0
    private var lastIm: Float = 0

    public init() {}

    public func process(re: UnsafePointer<Float>, im: UnsafePointer<Float>, count: Int, gain: Float, output: UnsafeMutablePointer<Float>) {
        var pr = lastRe, pi = lastIm
        for k in 0..<count {
            let r = re[k], i = im[k]
            let dr = r * pr + i * pi
            let di = i * pr - r * pi
            output[k] = atan2f(di, dr) * gain
            pr = r
            pi = i
        }
        lastRe = pr
        lastIm = pi
    }
}

public struct DCBlocker {
    private var x1: Float = 0
    private var y1: Float = 0
    private let r: Float

    public init(cutoff: Double, sampleRate: Double) {
        r = Float(exp(-2 * .pi * cutoff / sampleRate))
    }

    public mutating func process(_ p: UnsafeMutablePointer<Float>, count: Int) {
        var a = x1, b = y1
        for k in 0..<count {
            let x = p[k]
            let y = x - a + r * b
            a = x
            b = y
            p[k] = y
        }
        x1 = a
        y1 = b
    }
}

/// Automatic notch. A long FFT of the audio, averaged over about a second, finds steady tones (carriers,
/// heterodyne whistles) that stand out from their surroundings; speech moves around and averages away.
/// Each tone gets a narrow IIR notch, so the audio itself sees no FFT latency. The averaging lets it
/// catch tones that are far weaker than the total audio.
public final class AutoNotch {
    private struct Notch {
        var frequency: Float
        var c: Float = 0
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    }

    public static let maxNotches = 8
    private let sampleRate: Float
    private let size: Int
    private let hop: Int
    private let binHz: Float
    /// Pole radius for a notch about 50 Hz wide.
    private let r: Float
    private let alpha: Float
    /// A tone must stand this far above the local median to get a notch; half as far to keep one.
    private let threshold: Float = 4
    private let warmup: Int
    private let fft: vDSP_DFT_Setup
    private var window: [Float]
    private var history: [Float]
    private var historyPos = 0
    private var sinceDetect = 0
    private var frames = 0
    private var smooth: [Float]
    private var re: [Float], im: [Float], outRe: [Float], outIm: [Float]
    private var scratch: [Float] = []
    private var notches: [Notch] = []

    public init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        size = sampleRate > 64_000 ? 8192 : 4096
        hop = size / 2
        binHz = Float(sampleRate) / Float(size)
        r = 1 - .pi * 50 / Float(sampleRate)
        let averaging: Float = 1
        alpha = 1 - exp(-Float(hop) / Float(sampleRate) / averaging)
        warmup = Int((averaging * Float(sampleRate) / Float(hop)).rounded(.up))
        fft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        history = [Float](repeating: 0, count: size)
        smooth = [Float](repeating: 0, count: size / 2 + 1)
        re = [Float](repeating: 0, count: size)
        im = re
        outRe = re
        outIm = re
    }

    deinit { vDSP_DFT_DestroySetup(fft) }

    /// Frequencies currently notched, in Hz.
    public var frequencies: [Float] { notches.map(\.frequency) }

    public func reset() {
        vDSP_vclr(&history, 1, vDSP_Length(size))
        vDSP_vclr(&smooth, 1, vDSP_Length(smooth.count))
        historyPos = 0
        sinceDetect = 0
        frames = 0
        notches = []
    }

    /// `maxFrequency`: upper edge of the audio passband; tones are only searched below it.
    public func process(_ x: UnsafeMutablePointer<Float>, count: Int, maxFrequency: Double) {
        var done = 0
        while done < count {
            let n = min(count - done, hop - sinceDetect)
            let p = x + done
            for k in 0..<n {
                history[historyPos] = p[k]
                historyPos = historyPos + 1 == size ? 0 : historyPos + 1
            }
            filter(p, count: n)
            sinceDetect += n
            done += n
            if sinceDetect == hop {
                sinceDetect = 0
                detect(maxFrequency: Float(maxFrequency))
            }
        }
    }

    private func filter(_ x: UnsafeMutablePointer<Float>, count: Int) {
        let r = r, r2 = r * r
        notches.withUnsafeMutableBufferPointer { ns in
            for i in ns.indices {
                var t = ns[i]
                let c = t.c
                for k in 0..<count {
                    let v = x[k]
                    let y = v + c * t.x1 + t.x2 - r * c * t.y1 - r2 * t.y2
                    t.x2 = t.x1
                    t.x1 = v
                    t.y2 = t.y1
                    t.y1 = y
                    x[k] = y
                }
                ns[i] = t
            }
        }
    }

    private func detect(maxFrequency: Float) {
        // Oldest sample first.
        let tail = size - historyPos
        history.withUnsafeBufferPointer { h in
            re.withUnsafeMutableBufferPointer { d in
                d.baseAddress!.update(from: h.baseAddress! + historyPos, count: tail)
                (d.baseAddress! + tail).update(from: h.baseAddress!, count: historyPos)
            }
        }
        re.inPlace { vDSP_vmul($0, 1, window, 1, $0, 1, vDSP_Length(size)) }
        vDSP_vclr(&im, 1, vDSP_Length(size))
        vDSP_DFT_Execute(fft, re, im, &outRe, &outIm)
        let half = size / 2
        let a = frames == 0 ? 1 : alpha
        for b in 0...half {
            let p = outRe[b] * outRe[b] + outIm[b] * outIm[b]
            smooth[b] += a * (p - smooth[b])
        }
        frames += 1
        guard frames >= warmup else { return }

        let lo = max(2, Int((100 / binHz).rounded(.up)))
        let hi = min(half - 2, Int(min(maxFrequency, 0.45 * sampleRate) / binHz))
        guard hi > lo + 4 else { notches = []; return }
        let reach = max(8, Int(375 / binHz))
        var found: [(frequency: Float, excess: Float)] = []
        for b in (lo + 1)..<hi where smooth[b] > smooth[b - 1] && smooth[b] >= smooth[b + 1] {
            // Median of the neighbourhood within the passband.
            let from = max(lo, b - reach), to = min(hi, b + reach)
            scratch.removeAll(keepingCapacity: true)
            scratch.append(contentsOf: smooth[from...to])
            scratch.sort()
            let floor = max(scratch[scratch.count / 2], 1e-20)
            let f = Float(b) * binHz
            let kept = notches.contains { abs($0.frequency - f) < 2 * binHz }
            let excess = smooth[b] / floor
            guard excess > (kept ? threshold / 2 : threshold) else { continue }
            // Parabolic interpolation on the log spectrum for a sub-bin frequency.
            let l = log(smooth[b - 1] + 1e-30), m = log(smooth[b]), rr = log(smooth[b + 1] + 1e-30)
            let den = l - 2 * m + rr
            let d = den < 0 ? max(-0.5, min(0.5, 0.5 * (l - rr) / den)) : 0
            found.append(((Float(b) + d) * binHz, excess))
        }
        found.sort { $0.excess > $1.excess }
        var next: [Notch] = []
        for t in found.prefix(AutoNotch.maxNotches) {
            // Keep a tracked notch's state so a drifting tone does not click.
            var n = notches.first { abs($0.frequency - t.frequency) < 2 * binHz } ?? Notch(frequency: t.frequency)
            n.frequency = t.frequency
            n.c = -2 * cos(2 * .pi * t.frequency / sampleRate)
            next.append(n)
        }
        notches = next
    }
}

/// One-pole de-emphasis (50 µs Europe, 75 µs Americas).
public struct Deemphasis {
    private var y: Float = 0
    private let a: Float

    public init(tau: Double, sampleRate: Double) {
        a = tau > 0 ? Float(1 - exp(-1 / (sampleRate * tau))) : 1
    }

    public mutating func process(_ p: UnsafeMutablePointer<Float>, count: Int) {
        guard a < 1 else { return }
        var s = y
        for k in 0..<count {
            s += a * (p[k] - s)
            p[k] = s
        }
        y = s
    }
}

/// Second-order IIR section (RBJ cookbook), direct form I.
public struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    public static func lowpass(cutoff: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * .pi * cutoff / sampleRate, c = cos(w)
        return Biquad(b: [(1 - c) / 2, 1 - c, (1 - c) / 2], w: w, q: q)
    }

    public static func highpass(cutoff: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * .pi * cutoff / sampleRate, c = cos(w)
        return Biquad(b: [(1 + c) / 2, -(1 + c), (1 + c) / 2], w: w, q: q)
    }

    private init(b: [Double], w: Double, q: Double) {
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        b0 = Float(b[0] / a0)
        b1 = Float(b[1] / a0)
        b2 = Float(b[2] / a0)
        a1 = Float(-2 * cos(w) / a0)
        a2 = Float((1 - alpha) / a0)
    }

    public mutating func process(_ p: UnsafeMutablePointer<Float>, count: Int) {
        var xa = x1, xb = x2, ya = y1, yb = y2
        for k in 0..<count {
            let x = p[k]
            let y = b0 * x + b1 * xa + b2 * xb - a1 * ya - a2 * yb
            xb = xa
            xa = x
            yb = ya
            ya = y
            p[k] = y
        }
        x1 = xa
        x2 = xb
        y1 = ya
        y2 = yb
    }
}

/// Audio chain after the NFM discriminator: de-emphasis matching the transmitter's 6 dB/octave
/// pre-emphasis (530 µs, 0 dB at 1 kHz), a 300 Hz high-pass that removes DC and CTCSS tones, a 3.5 kHz
/// low-pass that removes hiss above the speech band, and a soft-knee limiter for over-deviation.
public struct NFMAudio {
    private var deemphasis: Deemphasis
    private let deemphasisGain: Float
    private var filters: [Biquad]

    public init(sampleRate: Double) {
        let tau = 530e-6
        deemphasis = Deemphasis(tau: tau, sampleRate: sampleRate)
        let corner = 1 / (2 * .pi * tau)
        deemphasisGain = Float(sqrt(1 + pow(1_000 / corner, 2)))
        filters = [
            .highpass(cutoff: 300, sampleRate: sampleRate, q: 0.5412),
            .highpass(cutoff: 300, sampleRate: sampleRate, q: 1.3066),
            .lowpass(cutoff: 3_500, sampleRate: sampleRate, q: 0.5412),
            .lowpass(cutoff: 3_500, sampleRate: sampleRate, q: 1.3066),
        ]
    }

    public mutating func process(_ p: UnsafeMutablePointer<Float>, count: Int) {
        deemphasis.process(p, count: count)
        var g = deemphasisGain
        vDSP_vsmul(p, 1, &g, p, 1, vDSP_Length(count))
        for i in filters.indices { filters[i].process(p, count: count) }
        let knee: Float = 0.8, room: Float = 1 - knee
        for k in 0..<count {
            let a = abs(p[k])
            if a > knee { p[k] = copysignf(knee + room * tanhf((a - knee) / room), p[k]) }
        }
    }
}

/// Peak-tracking AGC with hang, for AM/SSB/CW.
public final class AGC {
    public let sampleRate: Double
    private var peak: Float = 1e-4
    private var hang = 0
    private var gain: Float = 1
    public private(set) var currentGainDB: Float = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    public func process(_ x: UnsafeMutablePointer<Float>, count: Int, mode: AGCMode, manualGainDB: Float) {
        if mode == .off {
            var g = powf(10, manualGainDB / 20)
            vDSP_vsmul(x, 1, &g, x, 1, vDSP_Length(count))
            var lo: Float = -1, hi: Float = 1
            vDSP_vclip(x, 1, &lo, &hi, x, 1, vDSP_Length(count))
            currentGainDB = manualGainDB
            return
        }
        let (decayTime, hangTime): (Double, Double) = {
            switch mode {
            case .fast: return (0.08, 0.02)
            case .medium: return (0.3, 0.15)
            default: return (1.2, 0.5)
            }
        }()
        let attack = Float(1 - exp(-1 / (sampleRate * 0.002)))
        let decay = Float(exp(-1 / (sampleRate * decayTime)))
        let gainSmooth = Float(1 - exp(-1 / (sampleRate * 0.005)))
        let hangSamples = Int(sampleRate * hangTime)
        let target: Float = 0.3
        let maxGain: Float = 30_000
        var p = peak, h = hang, g = gain
        for k in 0..<count {
            let env = abs(x[k])
            if env > p {
                p += attack * (env - p)
                h = hangSamples
            } else if h > 0 {
                h -= 1
            } else {
                p *= decay
            }
            let want = min(target / max(p, 1e-9), maxGain)
            // Drop instantly, recover smoothly.
            g = want < g ? want : g + gainSmooth * (want - g)
            x[k] = max(-1, min(1, x[k] * g))
        }
        peak = p
        hang = h
        gain = g
        currentGainDB = 20 * log10f(max(g, 1e-9))
    }
}

/// FM stereo decoder: 19 kHz pilot PLL, 38 kHz L−R demodulation, audio low-pass + decimation.
public final class StereoDecoder {
    public let inputRate: Double
    public let decimation: Int
    private let pilotFilter: RealDecimator
    private let delay: DelayLine
    private let sumDecimator: RealDecimator
    private let diffDecimator: RealDecimator
    private var phase: Double = 0
    private var freq: Double
    private let freqCenter: Double
    private let freqLimit: Double
    private let alpha: Double
    private let beta: Double
    private var amplitude: Double = 0
    private var lockAverage: Double = 0
    public private(set) var locked = false
    private var diffInput: [Float] = []
    public private(set) var left: [Float] = []
    public private(set) var right: [Float] = []

    public init(inputRate: Double, decimation: Int) {
        self.inputRate = inputRate
        self.decimation = decimation
        let pilotTaps = FIR.realBandpass(center: 19_000 / inputRate, halfWidth: 1_500 / inputRate, transition: 3_000 / inputRate, maxTaps: 1023)
        pilotFilter = RealDecimator(factor: 1, taps: pilotTaps)
        delay = DelayLine(delay: pilotFilter.delay)
        let audioRate = inputRate / Double(decimation)
        let audioCutoff = min(15_000, audioRate * 0.42)
        let audioTaps = FIR.lowpass(cutoff: audioCutoff / inputRate,
                                    transition: max(2_000, audioRate * 0.5 - audioCutoff) / inputRate,
                                    maxTaps: 1023)
        sumDecimator = RealDecimator(factor: decimation, taps: audioTaps)
        diffDecimator = RealDecimator(factor: decimation, taps: audioTaps)
        freqCenter = 2 * .pi * 19_000 / inputRate
        freq = freqCenter
        freqLimit = 2 * .pi * 40 / inputRate
        let wn = 2 * Double.pi * 25 / inputRate
        alpha = 2 * 0.707 * wn
        beta = wn * wn
    }

    /// Returns the number of audio samples in `left`/`right`.
    public func process(mpx: UnsafePointer<Float>, count: Int, stereoEnabled: Bool) -> Int {
        pilotFilter.process(mpx, count: count)
        delay.process(mpx, count: count)
        if diffInput.count < count { diffInput = [Float](repeating: 0, count: count) }

        var ph = phase, f = freq, amp = amplitude, lockAvg = lockAverage
        let ampSmooth = 1 / (inputRate * 0.05)
        pilotFilter.output.withUnsafeBufferPointer { bp in
            delay.output.withUnsafeBufferPointer { dp in
                for k in 0..<count {
                    let p = Double(bp[k])
                    let s = sin(ph), c = cos(ph)
                    amp += (abs(p) * .pi / 2 - amp) * ampSmooth
                    let norm = max(amp / 2, 1e-4)
                    let err = max(-1, min(1, p * -s / norm))
                    lockAvg += (p * c / norm - lockAvg) * ampSmooth
                    f = max(freqCenter - freqLimit, min(freqCenter + freqLimit, f + beta * err))
                    ph += f + alpha * err
                    if ph > .pi { ph -= 2 * .pi }
                    // L−R sits on sin(2ωt) where the pilot is sin(ωt): −sin(2φ) in our cosine-locked frame.
                    diffInput[k] = Float(2 * Double(dp[k]) * -(2 * s * c))
                }
            }
        }
        phase = ph
        freq = f
        amplitude = amp
        lockAverage = lockAvg
        if locked {
            locked = lockAvg > 0.5 && amp > 0.02
        } else {
            locked = lockAvg > 0.75 && amp > 0.03
        }

        let n = delay.output.withUnsafeBufferPointer { sumDecimator.process($0.baseAddress!, count: count) }
        let m = diffDecimator.process(diffInput, count: count)
        assert(n == m)
        if left.count < n {
            left = [Float](repeating: 0, count: n + 1024)
            right = left
        }
        let useStereo = stereoEnabled && locked
        let sums = sumDecimator.output
        let diffs = diffDecimator.output
        for k in 0..<n {
            let sum = sums[k]
            if useStereo {
                let diff = diffs[k]
                left[k] = sum + diff
                right[k] = sum - diff
            } else {
                left[k] = sum
                right[k] = sum
            }
        }
        return n
    }
}
