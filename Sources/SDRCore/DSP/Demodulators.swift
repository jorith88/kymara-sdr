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

    public var id: String { rawValue }

    public var defaultBandwidth: Double {
        switch self {
        case .am: return 8_000
        case .nfm: return 12_500
        case .wfm: return 180_000
        case .usb, .lsb: return 2_700
        case .cw: return 500
        case .dsb: return 6_000
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
        }
    }

    public var bandwidthRange: ClosedRange<Double> {
        switch self {
        case .wfm: return 30_000...220_000
        case .cw: return 50...3_000
        case .usb, .lsb: return 500...6_000
        default: return 1_000...40_000
        }
    }

    public var defaultStep: Double {
        switch self {
        case .am: return 5_000
        case .nfm: return 12_500
        case .wfm: return 100_000
        case .usb, .lsb, .dsb: return 100
        case .cw: return 10
        }
    }

    /// Filter passband edges relative to the VFO in Hz.
    public func filterEdges(bandwidth bw: Double) -> (lo: Double, hi: Double) {
        switch self {
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
