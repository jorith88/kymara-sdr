import Foundation
import Accelerate

public enum FIR {
    /// Number of taps for a Blackman-windowed filter with the given transition width (normalised to fs).
    public static func tapCount(transition: Double, maxTaps: Int = 4095) -> Int {
        var n = Int(ceil(5.5 / max(transition, 1e-6)))
        n = min(max(n, 15), maxTaps)
        return n | 1
    }

    /// Windowed-sinc low-pass. `cutoff` is normalised to the sample rate (0...0.5). Unity DC gain.
    public static func lowpass(cutoff: Double, taps n: Int) -> [Float] {
        let m = Double(n - 1) / 2
        var h = [Double](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            let x = Double(i) - m
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let a = 2 * .pi * Double(i) / Double(n - 1)
            let w = 0.42 - 0.5 * cos(a) + 0.08 * cos(2 * a)
            h[i] = sinc * w
            sum += h[i]
        }
        return h.map { Float($0 / sum) }
    }

    public static func lowpass(cutoff: Double, transition: Double, maxTaps: Int = 4095) -> [Float] {
        lowpass(cutoff: cutoff, taps: tapCount(transition: transition, maxTaps: maxTaps))
    }

    /// Complex band-pass passing [lo, hi] (normalised, may be negative) — a frequency-shifted low-pass.
    public static func complexBandpass(lo: Double, hi: Double, transition: Double, maxTaps: Int = 4095) -> (re: [Float], im: [Float]) {
        let proto = lowpass(cutoff: (hi - lo) / 2, transition: transition, maxTaps: maxTaps)
        let fc = (hi + lo) / 2
        let m = Double(proto.count - 1) / 2
        var re = [Float](repeating: 0, count: proto.count)
        var im = re
        for i in 0..<proto.count {
            let ph = 2 * .pi * fc * (Double(i) - m)
            re[i] = proto[i] * Float(cos(ph))
            im[i] = proto[i] * Float(sin(ph))
        }
        return (re, im)
    }

    /// Real band-pass around `center` with unity gain at the centre.
    public static func realBandpass(center: Double, halfWidth: Double, transition: Double, maxTaps: Int = 4095) -> [Float] {
        let proto = lowpass(cutoff: halfWidth, transition: transition, maxTaps: maxTaps)
        let m = Double(proto.count - 1) / 2
        return proto.enumerated().map { i, h in 2 * h * Float(cos(2 * .pi * center * (Double(i) - m))) }
    }
}

/// Streaming polyphase-free FIR decimator for one real channel (vDSP_desamp).
public final class RealDecimator {
    public let factor: Int
    public let taps: [Float]
    private var buffer: [Float]
    public private(set) var output: [Float] = []

    public init(factor: Int, taps: [Float]) {
        self.factor = max(1, factor)
        self.taps = taps.isEmpty ? [1] : taps
        buffer = [Float](repeating: 0, count: self.taps.count - 1)
        buffer.reserveCapacity(1 << 17)
    }

    public var delay: Int { (taps.count - 1) / 2 }

    /// Returns the number of samples written to `output`.
    @discardableResult
    public func process(_ input: UnsafePointer<Float>, count: Int) -> Int {
        buffer.append(contentsOf: UnsafeBufferPointer(start: input, count: count))
        let p = taps.count
        guard buffer.count >= p else { return 0 }
        let nOut = (buffer.count - p) / factor + 1
        if output.count < nOut { output = [Float](repeating: 0, count: nOut + 1024) }
        vDSP_desamp(buffer, vDSP_Stride(factor), taps, &output, vDSP_Length(nOut), vDSP_Length(p))
        buffer.removeFirst(nOut * factor)
        return nOut
    }

    public func reset() {
        buffer = [Float](repeating: 0, count: taps.count - 1)
    }
}

/// Complex signal, real taps.
public final class ComplexDecimator {
    private let i: RealDecimator
    private let q: RealDecimator

    public init(factor: Int, taps: [Float]) {
        i = RealDecimator(factor: factor, taps: taps)
        q = RealDecimator(factor: factor, taps: taps)
    }

    public var factor: Int { i.factor }
    public var outI: [Float] { i.output }
    public var outQ: [Float] { q.output }

    @discardableResult
    public func process(i inI: UnsafePointer<Float>, q inQ: UnsafePointer<Float>, count: Int) -> Int {
        let a = i.process(inI, count: count)
        let b = q.process(inQ, count: count)
        assert(a == b)
        return a
    }
}

/// Overlap-save FFT convolution for long complex filters (channel filters).
public final class FFTFilter {
    public let tapCount: Int
    public let fftSize: Int
    private let step: Int
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private var hRe: [Float]
    private var hIm: [Float]
    private var bufRe: [Float]
    private var bufIm: [Float]
    private var xRe: [Float]
    private var xIm: [Float]
    private var yRe: [Float]
    private var yIm: [Float]
    private var pendRe: [Float] = []
    private var pendIm: [Float] = []
    public private(set) var outRe: [Float] = []
    public private(set) var outIm: [Float] = []

    public init(tapsRe: [Float], tapsIm: [Float]) {
        tapCount = tapsRe.count
        var n = 1024
        while n < 2 * tapCount { n *= 2 }
        fftSize = n
        step = n - tapCount + 1
        forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(n), .INVERSE)!
        var tr = tapsRe + [Float](repeating: 0, count: n - tapCount)
        var ti = tapsIm + [Float](repeating: 0, count: n - tapCount)
        hRe = [Float](repeating: 0, count: n)
        hIm = [Float](repeating: 0, count: n)
        vDSP_DFT_Execute(forward, &tr, &ti, &hRe, &hIm)
        // Fold the 1/N of the inverse transform into H.
        var scale = 1 / Float(n)
        hRe.inPlace { vDSP_vsmul($0, 1, &scale, $0, 1, vDSP_Length(n)) }
        hIm.inPlace { vDSP_vsmul($0, 1, &scale, $0, 1, vDSP_Length(n)) }
        bufRe = [Float](repeating: 0, count: n)
        bufIm = bufRe
        xRe = bufRe
        xIm = bufRe
        yRe = bufRe
        yIm = bufRe
        pendRe.reserveCapacity(1 << 16)
        pendIm.reserveCapacity(1 << 16)
        outRe.reserveCapacity(1 << 16)
        outIm.reserveCapacity(1 << 16)
    }

    public convenience init(realTaps: [Float]) {
        self.init(tapsRe: realTaps, tapsIm: [Float](repeating: 0, count: realTaps.count))
    }

    deinit {
        vDSP_DFT_DestroySetup(inverse)
        vDSP_DFT_DestroySetup(forward)
    }

    @discardableResult
    public func process(re: UnsafePointer<Float>, im: UnsafePointer<Float>, count: Int) -> Int {
        pendRe.append(contentsOf: UnsafeBufferPointer(start: re, count: count))
        pendIm.append(contentsOf: UnsafeBufferPointer(start: im, count: count))
        outRe.removeAll(keepingCapacity: true)
        outIm.removeAll(keepingCapacity: true)
        let n = fftSize
        let keep = tapCount - 1
        var offset = 0
        while pendRe.count - offset >= step {
            bufRe.withUnsafeMutableBufferPointer { b in
                if keep > 0 { b.baseAddress!.update(from: b.baseAddress! + step, count: keep) }
                pendRe.withUnsafeBufferPointer { p in (b.baseAddress! + keep).update(from: p.baseAddress! + offset, count: step) }
            }
            bufIm.withUnsafeMutableBufferPointer { b in
                if keep > 0 { b.baseAddress!.update(from: b.baseAddress! + step, count: keep) }
                pendIm.withUnsafeBufferPointer { p in (b.baseAddress! + keep).update(from: p.baseAddress! + offset, count: step) }
            }
            vDSP_DFT_Execute(forward, bufRe, bufIm, &xRe, &xIm)
            xRe.withUnsafeMutableBufferPointer { xr in
                xIm.withUnsafeMutableBufferPointer { xi in
                    hRe.withUnsafeMutableBufferPointer { hr in
                        hIm.withUnsafeMutableBufferPointer { hi in
                            var x = DSPSplitComplex(realp: xr.baseAddress!, imagp: xi.baseAddress!)
                            var h = DSPSplitComplex(realp: hr.baseAddress!, imagp: hi.baseAddress!)
                            vDSP_zvmul(&x, 1, &h, 1, &x, 1, vDSP_Length(n), 1)
                        }
                    }
                }
            }
            vDSP_DFT_Execute(inverse, xRe, xIm, &yRe, &yIm)
            outRe.append(contentsOf: yRe[keep..<n])
            outIm.append(contentsOf: yIm[keep..<n])
            offset += step
        }
        if offset > 0 {
            pendRe.removeFirst(offset)
            pendIm.removeFirst(offset)
        }
        return outRe.count
    }
}

/// Frequency shifter (complex NCO mixer), phase-continuous across blocks.
public final class Mixer {
    private var pr = 1.0
    private var pi = 0.0

    public init() {}

    /// Shifts the signal down by `frequency` Hz (a signal at +frequency moves to DC).
    public func mix(re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>, count: Int, frequency: Double, sampleRate: Double) {
        guard frequency != 0 else { return }
        let w = -2 * Double.pi * frequency / sampleRate
        let dr = cos(w), di = sin(w)
        var r = pr, i = pi
        for k in 0..<count {
            let a = Double(re[k]), b = Double(im[k])
            re[k] = Float(a * r - b * i)
            im[k] = Float(a * i + b * r)
            let nr = r * dr - i * di
            i = r * di + i * dr
            r = nr
        }
        let m = 1 / (r * r + i * i).squareRoot()
        pr = r * m
        pi = i * m
    }
}

/// Pure sample delay.
public final class DelayLine {
    private var history: [Float]
    public private(set) var output: [Float] = []

    public init(delay: Int) {
        history = [Float](repeating: 0, count: delay)
    }

    public func process(_ input: UnsafePointer<Float>, count: Int) {
        history.append(contentsOf: UnsafeBufferPointer(start: input, count: count))
        output.removeAll(keepingCapacity: true)
        output.append(contentsOf: history[0..<count])
        history.removeFirst(count)
    }
}
