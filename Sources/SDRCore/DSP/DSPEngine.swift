import Foundation
import Accelerate

public struct DSPConfig: Equatable, Sendable {
    public var sampleRate: Double = 2_400_000
    /// VFO A, always running.
    public var vfoA = ReceiverConfig()
    /// VFO B, a second receiver in the same band; nil when off.
    public var vfoB: ReceiverConfig?
    /// De-emphasis time constant in seconds (0 = off).
    public var deemphasis: Double = 50e-6
    public var cwPitch: Double = 700
    public var dcCorrection = true
    public var swapIQ = false
    public var fftSize = 8192
    public var spectrumRate: Double = 30
    public var waterfallRate: Double = 25
    /// 0 = no averaging, close to 1 = heavy averaging.
    public var averaging: Float = 0.5
    public var peakDecay: Float = 0.5

    public init() {}

    public subscript(vfo: VFOID) -> ReceiverConfig? {
        get { vfo == .a ? vfoA : vfoB }
        set {
            if vfo == .a { if let newValue { vfoA = newValue } } else { vfoB = newValue }
        }
    }
}

public struct DSPStatus: Sendable {
    public var vfoA = ReceiverStatus()
    /// Nil while VFO B is off.
    public var vfoB: ReceiverStatus?
    public var audioRate: Double = 48_000
    public var overload = false
    public var samplesPerSecond: Double = 0

    public subscript(vfo: VFOID) -> ReceiverStatus? { vfo == .a ? vfoA : vfoB }
}

/// The receive chain: sample conversion, DC removal and the spectrum, then one `Receiver` per VFO whose audio is
/// mixed into `audioRing`. `process` is called from the source thread; configuration is applied from any thread.
public final class DSPEngine: @unchecked Sendable {
    public struct Rates: Equatable {
        public let decim1: Int
        public let rate1: Double
        public let decim2: Int
        public let audioRate: Double
    }

    /// Stage 1 brings the signal to ~240 kHz (enough for broadcast FM), stage 2 to ~48 kHz audio.
    public static func rates(for sampleRate: Double) -> Rates {
        let d1 = max(1, Int(sampleRate / 240_000))
        let r1 = sampleRate / Double(d1)
        let d2 = max(1, Int((r1 / 48_000).rounded()))
        return Rates(decim1: d1, rate1: r1, decim2: d2, audioRate: r1 / Double(d2))
    }

    /// Usable part of the band either side of the centre; a VFO beyond it is out of band.
    public static let usableFraction = 0.48

    public let spectrum = SpectrumStore()
    public let audioRing = AudioRingBuffer()
    public let recorder = Recorder()

    private let configLock = NSLock()
    private var pendingConfig = DSPConfig()
    private let processLock = NSLock()
    private let statusLock = NSLock()
    private var currentStatus = DSPStatus()

    // Chain state (processLock).
    private var cfg = DSPConfig()
    private var built = false
    private var rates = DSPEngine.rates(for: 2_400_000)
    private var analyzer = SpectrumAnalyzer(size: 8192)
    private var spectrumFrame: [Float] = []
    private var averaged: [Float] = []
    private var peak: [Float] = []
    private var waterfallSum: [Float] = []
    private var waterfallCount = 0
    private var samplesSinceSpectrum: Double = 0
    private var samplesSinceLine: Double = 0
    private let receivers = [Receiver(), Receiver()]
    /// Audio waiting to be mixed, per receiver (block sizes differ between receivers).
    private var pending = [AudioFIFO(), AudioFIFO()]
    /// Audio samples owed while no receiver is in band, so silence keeps the output going.
    private var silenceDebt: Double = 0
    private var dcI: Float = 0
    private var dcQ: Float = 0
    private var rateCounter = 0
    private var rateStart = DispatchTime.now().uptimeNanoseconds

    // Work buffers.
    private var floats: [Float] = []
    private var bufI: [Float] = []
    private var bufQ: [Float] = []
    private var mixL: [Float] = []
    private var mixR: [Float] = []
    private var outL: [Float] = []
    private var outR: [Float] = []

    public init() {}

    public var config: DSPConfig {
        get { configLock.withLock { pendingConfig } }
        set { configLock.withLock { pendingConfig = newValue } }
    }

    public var status: DSPStatus { statusLock.withLock { currentStatus } }

    /// Forget the station's RDS data on one VFO (call after retuning it).
    public func resetRDS(vfo: VFOID = .a) {
        receivers[vfo == .a ? 0 : 1].resetRDS()
        statusLock.withLock {
            if vfo == .a { currentStatus.vfoA.rds = RDSInfo() } else { currentStatus.vfoB?.rds = RDSInfo() }
        }
    }

    public var audioRate: Double { DSPEngine.rates(for: config.sampleRate).audioRate }

    /// Clears all filter state (call when the source restarts).
    public func reset() {
        processLock.withLock {
            built = false
            dcI = 0
            dcQ = 0
            rateCounter = 0
            rateStart = DispatchTime.now().uptimeNanoseconds
        }
        spectrum.reset()
    }

    // MARK: Building

    private func rebuild(_ c: DSPConfig, previous: DSPConfig?) {
        if previous == nil || previous!.sampleRate != c.sampleRate {
            rates = DSPEngine.rates(for: c.sampleRate)
            receivers.forEach { $0.reset() }
            for k in pending.indices { pending[k].removeAll() }
            silenceDebt = 0
            audioRing.reset(sampleRate: rates.audioRate)
            if recorder.isRecordingAudio { recorder.stopAudio() }
        }
        if previous == nil || previous!.sampleRate != c.sampleRate || previous!.fftSize != c.fftSize {
            analyzer = SpectrumAnalyzer(size: c.fftSize)
            averaged = []
            peak = []
            waterfallSum = []
            waterfallCount = 0
        }
    }

    private func ensure(_ array: inout [Float], _ n: Int) {
        if array.count < n { array = [Float](repeating: 0, count: n) }
    }

    // MARK: Processing

    public func process(_ bytes: UnsafeBufferPointer<UInt8>) {
        process(.u8(bytes))
    }

    public func process(_ samples: IQSamples) {
        processLock.lock()
        defer { processLock.unlock() }

        let c = config
        if !built {
            rebuild(c, previous: nil)
            built = true
        } else if c != cfg {
            rebuild(c, previous: cfg)
        }
        if c.vfoB == nil && cfg.vfoB != nil {
            receivers[1].reset()
            pending[1].removeAll()
        }
        cfg = c

        recorder.writeIQ(samples)

        let n = samples.count
        guard n > 0 else { return }
        ensure(&floats, 2 * n)
        ensure(&bufI, n)
        ensure(&bufQ, n)

        // Samples → float in [-1, 1], then deinterleave.
        var scale: Float
        var offset: Float
        switch samples {
        case .u8(let b):
            guard let base = b.baseAddress else { return }
            vDSP_vfltu8(base, 1, &floats, 1, vDSP_Length(2 * n))
            scale = 1 / 127.5
            offset = -1
        case .s16(let b):
            guard let base = b.baseAddress else { return }
            vDSP_vflt16(base, 1, &floats, 1, vDSP_Length(2 * n))
            scale = 1 / 32768
            offset = 0
        }
        floats.withUnsafeMutableBufferPointer { f in
            vDSP_vsmsa(f.baseAddress!, 1, &scale, &offset, f.baseAddress!, 1, vDSP_Length(2 * n))
            bufI.withUnsafeMutableBufferPointer { i in
                bufQ.withUnsafeMutableBufferPointer { q in
                    var split = c.swapIQ
                        ? DSPSplitComplex(realp: q.baseAddress!, imagp: i.baseAddress!)
                        : DSPSplitComplex(realp: i.baseAddress!, imagp: q.baseAddress!)
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n))
                    }
                }
            }
        }

        // Overload: samples at the rails.
        var maxMag: Float = 0
        vDSP_maxmgv(floats, 1, &maxMag, vDSP_Length(2 * n))
        let overload = maxMag > 0.99

        bufI.withUnsafeMutableBufferPointer { ip in
            bufQ.withUnsafeMutableBufferPointer { qp in
                let i = ip.baseAddress!, q = qp.baseAddress!
                if c.dcCorrection { removeDC(i, q, n) }
                analyzer.push(re: i, im: q, count: n)
                spectrumStep(n, c)
            }
        }

        // Receivers.
        let configs = [c.vfoA, c.vfoB]
        var active: [Int] = []
        for k in 0..<2 {
            guard let rc = configs[k] else { continue }
            let receiver = receivers[k]
            guard abs(rc.vfoOffset) <= c.sampleRate * DSPEngine.usableFraction else {
                receiver.markOutOfBand()
                pending[k].removeAll()
                continue
            }
            active.append(k)
            let count = bufI.withUnsafeBufferPointer { i in
                bufQ.withUnsafeBufferPointer { q in
                    receiver.process(i: i.baseAddress!, q: q.baseAddress!, count: n, config: rc, global: c)
                }
            }
            pending[k].append(left: receiver.left, right: receiver.right, count: count)
        }
        // A receiver can only run ahead while another fills its first blocks; never let that grow.
        let limit = Int(0.25 * rates.audioRate)
        for k in active where pending[k].count > limit + (active.map { pending[$0].count }.min() ?? 0) {
            pending[k].removeFirst(pending[k].count - limit)
        }
        mixAudio(active: active, configs: configs, inputCount: n)

        rateCounter += n
        let now = DispatchTime.now().uptimeNanoseconds
        var measuredRate: Double?
        if now - rateStart > 1_000_000_000 {
            measuredRate = Double(rateCounter) / (Double(now - rateStart) / 1e9)
            rateCounter = 0
            rateStart = now
        }
        let statusA = receivers[0].status
        let statusB = c.vfoB != nil ? receivers[1].status : nil
        let audioRate = rates.audioRate
        statusLock.withLock {
            currentStatus.vfoA = statusA
            currentStatus.vfoB = statusB
            currentStatus.audioRate = audioRate
            currentStatus.overload = overload
            if let measuredRate { currentStatus.samplesPerSecond = measuredRate }
        }
    }

    /// Mixes what all in-band receivers have ready (each routed to its channels) into the recorder and the
    /// audio ring. Recording gets the mix without volume, the speakers with it; a muted VFO is left out of both.
    private func mixAudio(active: [Int], configs: [ReceiverConfig?], inputCount n: Int) {
        let count: Int
        if active.isEmpty {
            silenceDebt += Double(n) * rates.audioRate / cfg.sampleRate
            count = Int(silenceDebt)
            silenceDebt -= Double(count)
        } else {
            silenceDebt = 0
            count = active.map { pending[$0].count }.min()!
        }
        guard count > 0 else { return }
        ensure(&mixL, count)
        ensure(&mixR, count)
        ensure(&outL, count)
        ensure(&outR, count)
        vDSP_vclr(&mixL, 1, vDSP_Length(count))
        vDSP_vclr(&mixR, 1, vDSP_Length(count))
        vDSP_vclr(&outL, 1, vDSP_Length(count))
        vDSP_vclr(&outR, 1, vDSP_Length(count))
        for k in active {
            let rc = configs[k]!
            if !rc.muted {
                pending[k].withBuffers { l, r in
                    add(l, r, route: rc.output, gain: 1, count: count, intoLeft: &mixL, intoRight: &mixR)
                    add(l, r, route: rc.output, gain: rc.volume, count: count, intoLeft: &outL, intoRight: &outR)
                }
            }
            pending[k].removeFirst(count)
        }
        recorder.writeAudio(left: mixL, right: mixR, count: count)
        audioRing.write(left: outL, right: outR, count: count)
    }

    private func add(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, route: AudioRoute, gain: Float, count: Int,
                     intoLeft outL: inout [Float], intoRight outR: inout [Float]) {
        var g = gain
        let len = vDSP_Length(count)
        switch route {
        case .both:
            outL.inPlace { vDSP_vsma(l, 1, &g, $0, 1, $0, 1, len) }
            outR.inPlace { vDSP_vsma(r, 1, &g, $0, 1, $0, 1, len) }
        case .left, .right:
            // Mono to one side.
            var half = gain / 2
            if route == .left {
                outL.inPlace { vDSP_vsma(l, 1, &half, $0, 1, $0, 1, len) }
                outL.inPlace { vDSP_vsma(r, 1, &half, $0, 1, $0, 1, len) }
            } else {
                outR.inPlace { vDSP_vsma(l, 1, &half, $0, 1, $0, 1, len) }
                outR.inPlace { vDSP_vsma(r, 1, &half, $0, 1, $0, 1, len) }
            }
        }
    }

    private func removeDC(_ i: UnsafeMutablePointer<Float>, _ q: UnsafeMutablePointer<Float>, _ n: Int) {
        var mi: Float = 0, mq: Float = 0
        vDSP_meanv(i, 1, &mi, vDSP_Length(n))
        vDSP_meanv(q, 1, &mq, vDSP_Length(n))
        // Slow tracking so a carrier near DC is not eaten.
        let a: Float = 0.02
        dcI += a * (mi - dcI)
        dcQ += a * (mq - dcQ)
        var ni = -dcI, nq = -dcQ
        vDSP_vsadd(i, 1, &ni, i, 1, vDSP_Length(n))
        vDSP_vsadd(q, 1, &nq, q, 1, vDSP_Length(n))
    }

    private func spectrumStep(_ n: Int, _ c: DSPConfig) {
        samplesSinceSpectrum += Double(n)
        samplesSinceLine += Double(n)
        let interval = c.sampleRate / max(c.spectrumRate, c.waterfallRate, 1)
        guard samplesSinceSpectrum >= interval else { return }
        samplesSinceSpectrum = min(samplesSinceSpectrum - interval, interval)

        analyzer.compute(into: &spectrumFrame)
        let size = spectrumFrame.count
        if averaged.count != size {
            averaged = spectrumFrame
            peak = spectrumFrame
            waterfallSum = [Float](repeating: 0, count: size)
            waterfallCount = 0
        } else {
            // Exponential averaging in dB, rate-independent.
            let rate = max(c.spectrumRate, c.waterfallRate, 1)
            var alpha = c.averaging <= 0 ? 1 : Float(1 - pow(Double(c.averaging), 30 / rate))
            alpha = max(0.02, min(1, alpha))
            averaged.inPlace { vDSP_vintb($0, 1, spectrumFrame, 1, &alpha, $0, 1, vDSP_Length(size)) }
            var decay = -c.peakDecay * Float(30 / rate)
            peak.inPlace { vDSP_vsadd($0, 1, &decay, $0, 1, vDSP_Length(size)) }
            peak.inPlace { vDSP_vmax($0, 1, averaged, 1, $0, 1, vDSP_Length(size)) }
        }
        spectrum.publish(spectrum: averaged, peak: peak)

        waterfallSum.inPlace { vDSP_vadd($0, 1, spectrumFrame, 1, $0, 1, vDSP_Length(size)) }
        waterfallCount += 1
        let lineInterval = c.sampleRate / max(c.waterfallRate, 1)
        if samplesSinceLine >= lineInterval {
            samplesSinceLine = min(samplesSinceLine - lineInterval, lineInterval)
            var inv = 1 / Float(waterfallCount)
            var line = [Float](repeating: 0, count: size)
            vDSP_vsmul(waterfallSum, 1, &inv, &line, 1, vDSP_Length(size))
            spectrum.pushLine(line)
            vDSP_vclr(&waterfallSum, 1, vDSP_Length(size))
            waterfallCount = 0
        }
    }
}

/// Stereo audio waiting to be mixed.
struct AudioFIFO {
    private var left: [Float] = []
    private var right: [Float] = []
    private(set) var count = 0

    mutating func append(left l: [Float], right r: [Float], count n: Int) {
        guard n > 0 else { return }
        if left.count < count + n {
            left.append(contentsOf: [Float](repeating: 0, count: count + n - left.count))
            right.append(contentsOf: [Float](repeating: 0, count: count + n - right.count))
        }
        left.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: count).update(from: l, count: n) }
        right.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: count).update(from: r, count: n) }
        count += n
    }

    func withBuffers(_ body: (UnsafePointer<Float>, UnsafePointer<Float>) -> Void) {
        left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in body(l.baseAddress!, r.baseAddress!) } }
    }

    mutating func removeFirst(_ n: Int) {
        let rest = count - n
        if rest > 0 {
            left.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: $0.baseAddress! + n, count: rest) }
            right.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: $0.baseAddress! + n, count: rest) }
        }
        count = rest
    }

    mutating func removeAll() { count = 0 }
}
