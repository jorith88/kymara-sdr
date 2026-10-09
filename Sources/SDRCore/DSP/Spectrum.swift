import Foundation
import Accelerate

/// FFT power spectrum of the most recent `size` samples, in dBFS, DC in the centre.
public final class SpectrumAnalyzer {
    public static let sizes = [1024, 2048, 4096, 8192, 16384, 32768, 65536]

    public let size: Int
    private var histRe: [Float]
    private var histIm: [Float]
    private var writePos = 0
    private let window: [Float]
    private let setup: vDSP_DFT_Setup
    private var inRe: [Float]
    private var inIm: [Float]
    private var outRe: [Float]
    private var outIm: [Float]
    private var power: [Float]
    private let powerScale: Float

    public init(size: Int) {
        self.size = size
        histRe = [Float](repeating: 0, count: size)
        histIm = histRe
        inRe = histRe
        inIm = histRe
        outRe = histRe
        outIm = histRe
        power = histRe
        var w = [Float](repeating: 0, count: size)
        // 4-term Blackman-Harris: −92 dB sidelobes.
        for i in 0..<size {
            let a = 2 * Double.pi * Double(i) / Double(size)
            w[i] = Float(0.35875 - 0.48829 * cos(a) + 0.14128 * cos(2 * a) - 0.01168 * cos(3 * a))
        }
        window = w
        let gain = w.reduce(0, +)
        powerScale = 1 / (gain * gain)
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    public func push(re: UnsafePointer<Float>, im: UnsafePointer<Float>, count: Int) {
        var srcOffset = 0
        var remaining = count
        if remaining > size {
            srcOffset = remaining - size
            remaining = size
        }
        while remaining > 0 {
            let chunk = min(remaining, size - writePos)
            histRe.withUnsafeMutableBufferPointer { ($0.baseAddress! + writePos).update(from: re + srcOffset, count: chunk) }
            histIm.withUnsafeMutableBufferPointer { ($0.baseAddress! + writePos).update(from: im + srcOffset, count: chunk) }
            writePos = (writePos + chunk) % size
            srcOffset += chunk
            remaining -= chunk
        }
    }

    /// Computes a new spectrum into `out` (size elements, dBFS).
    public func compute(into out: inout [Float]) {
        if out.count != size { out = [Float](repeating: -150, count: size) }
        let tail = size - writePos
        // Oldest sample first.
        inRe.withUnsafeMutableBufferPointer { d in
            histRe.withUnsafeBufferPointer { s in
                d.baseAddress!.update(from: s.baseAddress! + writePos, count: tail)
                (d.baseAddress! + tail).update(from: s.baseAddress!, count: writePos)
            }
        }
        inIm.withUnsafeMutableBufferPointer { d in
            histIm.withUnsafeBufferPointer { s in
                d.baseAddress!.update(from: s.baseAddress! + writePos, count: tail)
                (d.baseAddress! + tail).update(from: s.baseAddress!, count: writePos)
            }
        }
        let n = vDSP_Length(size)
        inRe.inPlace { vDSP_vmul($0, 1, window, 1, $0, 1, n) }
        inIm.inPlace { vDSP_vmul($0, 1, window, 1, $0, 1, n) }
        vDSP_DFT_Execute(setup, inRe, inIm, &outRe, &outIm)
        outRe.withUnsafeMutableBufferPointer { r in
            outIm.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, n)
            }
        }
        var scale = powerScale
        var floor: Float = 1e-20
        power.inPlace { vDSP_vsmsa($0, 1, &scale, &floor, $0, 1, n) }
        var ref: Float = 1
        let half = size / 2
        // FFT shift while converting to dB.
        out.withUnsafeMutableBufferPointer { o in
            power.withUnsafeBufferPointer { p in
                vDSP_vdbcon(p.baseAddress! + half, 1, &ref, o.baseAddress!, 1, vDSP_Length(half), 0)
                vDSP_vdbcon(p.baseAddress!, 1, &ref, o.baseAddress! + half, 1, vDSP_Length(half), 0)
            }
        }
    }
}

/// Hand-off point between the DSP thread and the renderers.
public final class SpectrumStore: @unchecked Sendable {
    private let lock = NSLock()
    private var spectrum: [Float] = []
    private var peak: [Float] = []
    private var version = 0
    private var lines: [[Float]] = []
    /// The latest waterfall lines, kept after the renderer drains them (for auto range).
    private var recent: [[Float]] = []

    public init() {}

    func publish(spectrum s: [Float], peak p: [Float]) {
        lock.lock()
        spectrum = s
        peak = p
        version &+= 1
        lock.unlock()
    }

    func pushLine(_ line: [Float]) {
        lock.lock()
        lines.append(line)
        if lines.count > 512 { lines.removeFirst(lines.count - 512) }
        recent.append(line)
        if recent.count > 16 { recent.removeFirst(recent.count - 16) }
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        spectrum = []
        peak = []
        lines = []
        recent = []
        version &+= 1
        lock.unlock()
    }

    public func withLatest<R>(_ body: (_ spectrum: [Float], _ peak: [Float], _ version: Int) -> R) -> R {
        lock.lock()
        let s = spectrum, p = peak, v = version
        lock.unlock()
        return body(s, p, v)
    }

    public func recentLines() -> [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        return recent
    }

    public func drainLines() -> [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        let out = lines
        lines.removeAll(keepingCapacity: true)
        return out
    }
}
