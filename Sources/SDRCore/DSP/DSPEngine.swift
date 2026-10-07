import Foundation
import Accelerate

public struct DSPConfig: Equatable, Sendable {
    public var sampleRate: Double = 2_400_000
    /// VFO frequency relative to the tuner centre frequency.
    public var vfoOffset: Double = 0
    public var mode: DemodMode = .wfm
    public var bandwidth: Double = 180_000
    public var squelchEnabled = false
    public var squelchLevel: Float = -60
    public var agcMode: AGCMode = .medium
    public var afGainDB: Float = 20
    public var volume: Float = 0.5
    public var muted = false
    /// De-emphasis time constant in seconds (0 = off).
    public var deemphasis: Double = 50e-6
    public var stereo = true
    public var rds = true
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
}

public struct DSPStatus: Sendable {
    public var levelDB: Float = -150
    public var squelchOpen = false
    public var stereoLocked = false
    public var audioRate: Double = 48_000
    public var agcGainDB: Float = 0
    public var overload = false
    public var samplesPerSecond: Double = 0
    public var rds = RDSInfo()
}

/// The receive chain. `process` is called from the source thread; configuration is applied from any thread.
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
    private var mixer = Mixer()
    private var cwMixer = Mixer()
    private var stage1 = ComplexDecimator(factor: 1, taps: [1])
    private var stage2 = ComplexDecimator(factor: 1, taps: [1])
    private var channel = FFTFilter(realTaps: [1])
    private var fm = FMDemodulator()
    private var stereo: StereoDecoder?
    private var rds: RDSDecoder?
    private var rdsResetPending = false
    private var monoDecimator = RealDecimator(factor: 1, taps: [1])
    private var agc = AGC(sampleRate: 48_000)
    private var dcBlock = DCBlocker(cutoff: 30, sampleRate: 48_000)
    private var deemphL = Deemphasis(tau: 0, sampleRate: 48_000)
    private var deemphR = Deemphasis(tau: 0, sampleRate: 48_000)
    private var dcI: Float = 0
    private var dcQ: Float = 0
    private var squelchOpen = false
    private var rateCounter = 0
    private var rateStart = DispatchTime.now().uptimeNanoseconds

    // Work buffers.
    private var floats: [Float] = []
    private var bufI: [Float] = []
    private var bufQ: [Float] = []
    private var demod: [Float] = []
    private var left: [Float] = []
    private var right: [Float] = []
    private var outL: [Float] = []
    private var outR: [Float] = []

    public init() {}

    public var config: DSPConfig {
        get { configLock.withLock { pendingConfig } }
        set { configLock.withLock { pendingConfig = newValue } }
    }

    public var status: DSPStatus { statusLock.withLock { currentStatus } }

    /// Forget the current station's RDS data (call after retuning).
    public func resetRDS() {
        configLock.withLock { rdsResetPending = true }
        statusLock.withLock { currentStatus.rds = RDSInfo() }
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
        let structural = previous == nil || previous!.sampleRate != c.sampleRate || previous!.mode != c.mode
        if structural {
            rates = DSPEngine.rates(for: c.sampleRate)
            let fs = c.sampleRate
            if rates.decim1 > 1 {
                let r1 = rates.rate1
                stage1 = ComplexDecimator(factor: rates.decim1,
                                          taps: FIR.lowpass(cutoff: 0.46 * r1 / fs, transition: 0.12 * r1 / fs, maxTaps: 2047))
            } else {
                stage1 = ComplexDecimator(factor: 1, taps: [1])
            }
            let r1 = rates.rate1
            let ra = rates.audioRate
            if c.mode == .wfm {
                stereo = StereoDecoder(inputRate: r1, decimation: rates.decim2)
                rds = RDSDecoder(inputRate: r1)
                let cutoff = min(15_000, ra * 0.42)
                monoDecimator = RealDecimator(factor: rates.decim2,
                                              taps: FIR.lowpass(cutoff: cutoff / r1, transition: max(2_000, ra * 0.5 - cutoff) / r1, maxTaps: 1023))
            } else {
                stereo = nil
                rds = nil
                stage2 = rates.decim2 > 1
                    ? ComplexDecimator(factor: rates.decim2,
                                       taps: FIR.lowpass(cutoff: 0.44 * ra / r1, transition: 0.14 * ra / r1, maxTaps: 1023))
                    : ComplexDecimator(factor: 1, taps: [1])
            }
            fm = FMDemodulator()
            agc = AGC(sampleRate: ra)
            dcBlock = DCBlocker(cutoff: c.mode == .nfm ? 250 : 40, sampleRate: ra)
            mixer = Mixer()
            cwMixer = Mixer()
            audioRing.reset(sampleRate: ra)
            if recorder.isRecordingAudio { recorder.stopAudio() }
        }
        if structural || previous!.bandwidth != c.bandwidth {
            buildChannelFilter(c)
        }
        if structural || previous!.deemphasis != c.deemphasis {
            let tau = (c.mode == .wfm) ? c.deemphasis : 0
            deemphL = Deemphasis(tau: tau, sampleRate: rates.audioRate)
            deemphR = Deemphasis(tau: tau, sampleRate: rates.audioRate)
        }
        if structural || previous!.fftSize != c.fftSize {
            analyzer = SpectrumAnalyzer(size: c.fftSize)
            averaged = []
            peak = []
            waterfallSum = []
            waterfallCount = 0
        }
    }

    private func buildChannelFilter(_ c: DSPConfig) {
        let range = c.mode.bandwidthRange
        if c.mode == .wfm {
            let r1 = rates.rate1
            let bw = min(max(c.bandwidth, range.lowerBound), min(range.upperBound, 0.92 * r1))
            channel = FFTFilter(realTaps: FIR.lowpass(cutoff: bw / 2 / r1, transition: 25_000 / r1, maxTaps: 511))
        } else {
            let ra = rates.audioRate
            let bw = min(max(c.bandwidth, range.lowerBound), 0.84 * ra)
            let edges = c.mode.filterEdges(bandwidth: bw)
            let lo = max(edges.lo, -0.45 * ra), hi = min(edges.hi, 0.45 * ra)
            let transition = max(60, 0.1 * bw) / ra
            if lo == -hi {
                channel = FFTFilter(realTaps: FIR.lowpass(cutoff: hi / ra, transition: transition, maxTaps: 2047))
            } else {
                let taps = FIR.complexBandpass(lo: lo / ra, hi: hi / ra, transition: transition, maxTaps: 2047)
                channel = FFTFilter(tapsRe: taps.re, tapsIm: taps.im)
            }
        }
    }

    private func ensure(_ array: inout [Float], _ n: Int) {
        if array.count < n { array = [Float](repeating: 0, count: n) }
    }

    // MARK: Processing

    public func process(_ bytes: UnsafeBufferPointer<UInt8>) {
        processLock.lock()
        defer { processLock.unlock() }

        let c = config
        if !built {
            rebuild(c, previous: nil)
            built = true
        } else if c != cfg {
            rebuild(c, previous: cfg)
        }
        cfg = c

        recorder.writeIQ(bytes)

        let n = bytes.count / 2
        guard n > 0, let base = bytes.baseAddress else { return }
        ensure(&floats, 2 * n)
        ensure(&bufI, n)
        ensure(&bufQ, n)

        // u8 → float in [-1, 1], then deinterleave.
        vDSP_vfltu8(base, 1, &floats, 1, vDSP_Length(2 * n))
        var scale: Float = 1 / 127.5
        var offset: Float = -1
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
                mixer.mix(re: i, im: q, count: n, frequency: c.vfoOffset, sampleRate: c.sampleRate)
            }
        }

        let n1 = bufI.withUnsafeBufferPointer { i in
            bufQ.withUnsafeBufferPointer { q in stage1.process(i: i.baseAddress!, q: q.baseAddress!, count: n) }
        }
        guard n1 > 0 else { return }

        let audioCount: Int
        var levelDB: Float = -150
        if c.mode == .wfm {
            let nc = stage1.outI.withUnsafeBufferPointer { i in
                stage1.outQ.withUnsafeBufferPointer { q in channel.process(re: i.baseAddress!, im: q.baseAddress!, count: n1) }
            }
            guard nc > 0 else { return }
            levelDB = channelPower(nc)
            ensure(&demod, nc)
            let gain = Float(rates.rate1 / (2 * .pi * 75_000))
            channel.outRe.withUnsafeBufferPointer { re in
                channel.outIm.withUnsafeBufferPointer { im in
                    fm.process(re: re.baseAddress!, im: im.baseAddress!, count: nc, gain: gain, output: &demod)
                }
            }
            if configLock.withLock({ let r = rdsResetPending; rdsResetPending = false; return r }) {
                rds?.reset()
            }
            if c.rds, let rds {
                demod.withUnsafeBufferPointer { rds.process(mpx: $0.baseAddress!, count: nc) }
            }
            if let stereo {
                audioCount = stereo.process(mpx: demod, count: nc, stereoEnabled: c.stereo)
                ensure(&left, audioCount)
                ensure(&right, audioCount)
                left.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: stereo.left, count: audioCount) }
                right.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: stereo.right, count: audioCount) }
            } else {
                audioCount = monoDecimator.process(demod, count: nc)
                ensure(&left, audioCount)
                ensure(&right, audioCount)
                left.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: monoDecimator.output, count: audioCount) }
                right.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: monoDecimator.output, count: audioCount) }
            }
            left.withUnsafeMutableBufferPointer { deemphL.process($0.baseAddress!, count: audioCount) }
            right.withUnsafeMutableBufferPointer { deemphR.process($0.baseAddress!, count: audioCount) }
        } else {
            let n2 = stage1.outI.withUnsafeBufferPointer { i in
                stage1.outQ.withUnsafeBufferPointer { q in stage2.process(i: i.baseAddress!, q: q.baseAddress!, count: n1) }
            }
            guard n2 > 0 else { return }
            let nc = stage2.outI.withUnsafeBufferPointer { i in
                stage2.outQ.withUnsafeBufferPointer { q in channel.process(re: i.baseAddress!, im: q.baseAddress!, count: n2) }
            }
            guard nc > 0 else { return }
            levelDB = channelPower(nc)
            ensure(&left, nc)
            ensure(&right, nc)
            demodulateNarrow(nc, c)
            audioCount = nc
            right.withUnsafeMutableBufferPointer { r in left.withUnsafeBufferPointer { r.baseAddress!.update(from: $0.baseAddress!, count: nc) } }
        }

        // Squelch with 3 dB hysteresis.
        if c.squelchEnabled {
            squelchOpen = squelchOpen ? levelDB > c.squelchLevel - 3 : levelDB > c.squelchLevel
        } else {
            squelchOpen = true
        }
        if !squelchOpen {
            left.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: audioCount) }
            right.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: audioCount) }
        }

        recorder.writeAudio(left: left, right: right, count: audioCount)

        ensure(&outL, audioCount)
        ensure(&outR, audioCount)
        var vol = c.muted ? 0 : c.volume
        vDSP_vsmul(left, 1, &vol, &outL, 1, vDSP_Length(audioCount))
        vDSP_vsmul(right, 1, &vol, &outR, 1, vDSP_Length(audioCount))
        audioRing.write(left: outL, right: outR, count: audioCount)

        rateCounter += n
        let now = DispatchTime.now().uptimeNanoseconds
        var measuredRate: Double?
        if now - rateStart > 1_000_000_000 {
            measuredRate = Double(rateCounter) / (Double(now - rateStart) / 1e9)
            rateCounter = 0
            rateStart = now
        }
        let agcGain = agc.currentGainDB
        let locked = stereo?.locked ?? false
        let rdsInfo = c.mode == .wfm && c.rds ? rds?.info : nil
        let open = squelchOpen
        let audioRate = rates.audioRate
        statusLock.withLock {
            currentStatus.levelDB = levelDB
            currentStatus.squelchOpen = open
            currentStatus.stereoLocked = locked && c.mode == .wfm
            currentStatus.audioRate = audioRate
            currentStatus.agcGainDB = agcGain
            currentStatus.overload = overload
            if let measuredRate { currentStatus.samplesPerSecond = measuredRate }
            currentStatus.rds = rdsInfo ?? RDSInfo()
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

    private func channelPower(_ n: Int) -> Float {
        var pr: Float = 0, pi: Float = 0
        vDSP_measqv(channel.outRe, 1, &pr, vDSP_Length(n))
        vDSP_measqv(channel.outIm, 1, &pi, vDSP_Length(n))
        return 10 * log10f(max(pr + pi, 1e-15))
    }

    private func demodulateNarrow(_ n: Int, _ c: DSPConfig) {
        let ra = rates.audioRate
        left.withUnsafeMutableBufferPointer { lp in
            let out = lp.baseAddress!
            channel.outRe.withUnsafeBufferPointer { rp in
                channel.outIm.withUnsafeBufferPointer { ip in
                    let re = rp.baseAddress!, im = ip.baseAddress!
                    switch c.mode {
                    case .am:
                        var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: re), imagp: UnsafeMutablePointer(mutating: im))
                        vDSP_zvabs(&split, 1, out, 1, vDSP_Length(n))
                        dcBlock.process(out, count: n)
                        agc.process(out, count: n, mode: c.agcMode, manualGainDB: c.afGainDB)
                    case .nfm:
                        fm.process(re: re, im: im, count: n, gain: Float(ra / (2 * .pi * 5_000)), output: out)
                        dcBlock.process(out, count: n)
                    case .usb, .lsb, .dsb:
                        out.update(from: re, count: n)
                        agc.process(out, count: n, mode: c.agcMode, manualGainDB: c.afGainDB)
                    case .cw:
                        // Shift the carrier up to the CW pitch, then take the real part.
                        let mre = UnsafeMutablePointer(mutating: re), mim = UnsafeMutablePointer(mutating: im)
                        cwMixer.mix(re: mre, im: mim, count: n, frequency: -c.cwPitch, sampleRate: ra)
                        out.update(from: re, count: n)
                        agc.process(out, count: n, mode: c.agcMode, manualGainDB: c.afGainDB)
                    case .wfm:
                        break
                    }
                }
            }
        }
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
