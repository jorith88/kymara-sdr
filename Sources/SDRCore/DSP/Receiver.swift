import Foundation
import Accelerate

/// One of the two VFOs.
public enum VFOID: String, CaseIterable, Codable, Identifiable, Sendable {
    case a = "A"
    case b = "B"
    public var id: String { rawValue }
    public var other: VFOID { self == .a ? .b : .a }
}

/// Where a VFO's audio goes in the stereo output.
public enum AudioRoute: String, CaseIterable, Codable, Identifiable, Sendable {
    case both = "Both"
    case left = "Left"
    case right = "Right"
    public var id: String { rawValue }
}

/// Settings of one receiver (VFO); the rest of `DSPConfig` is shared.
public struct ReceiverConfig: Equatable, Sendable {
    /// VFO frequency relative to the tuner centre frequency.
    public var vfoOffset: Double = 0
    public var mode: DemodMode = .wfm
    public var bandwidth: Double = 180_000
    public var squelchEnabled = false
    public var squelchLevel: Float = -60
    /// FM modes: open on carrier-to-noise ratio instead of level, so no threshold needs setting.
    /// Other modes fall back to the level squelch.
    public var squelchAuto = false
    public var agcMode: AGCMode = .medium
    public var afGainDB: Float = 20
    /// Remove steady tones from the audio (modes where `DemodMode.supportsAutoNotch`).
    public var autoNotch = false
    public var volume: Float = 0.5
    public var muted = false
    public var output: AudioRoute = .both
    public var stereo = true
    public var rds = true
    /// RADE mode: the signal is in LSB (resolved from `RADESideband` by the caller, which knows the frequency).
    public var radeLSB = false

    public init() {}
}

public struct ReceiverStatus: Sendable {
    public var levelDB: Float = -150
    public var squelchOpen = false
    /// Estimated carrier-to-noise ratio in the channel (FM modes only).
    public var snrDB: Float?
    public var stereoLocked = false
    public var agcGainDB: Float = 0
    public var rds = RDSInfo()
    /// RADE decoder state (RADE mode only).
    public var rade: RADEStatus?
    /// The VFO lies inside the captured band (it is silent otherwise).
    public var inBand = true

    public init() {}
}

/// One demodulator chain: NCO mix to the VFO, decimation, channel filter, demodulation, squelch.
/// Produces squelched stereo audio at the engine's audio rate, before volume. Used under the engine's process lock.
final class Receiver {
    private var cfg = ReceiverConfig()
    private var global = DSPConfig()
    private var built = false
    private var rates = DSPEngine.rates(for: 2_400_000)
    private var mixer = Mixer()
    private var cwMixer = Mixer()
    private var stage1 = ComplexDecimator(factor: 1, taps: [1])
    private var stage2 = ComplexDecimator(factor: 1, taps: [1])
    private var channel = FFTFilter(realTaps: [1])
    private var fm = FMDemodulator()
    private var stereo: StereoDecoder?
    private var rds: RDSDecoder?
    private var rade: RADEDecoder?
    private let resetLock = NSLock()
    private var rdsResetPending = false
    private var monoDecimator = RealDecimator(factor: 1, taps: [1])
    private var agc = AGC(sampleRate: 48_000)
    private var notch = AutoNotch(sampleRate: 48_000)
    private var dcBlock = DCBlocker(cutoff: 30, sampleRate: 48_000)
    private var nfmAudio = NFMAudio(sampleRate: 48_000)
    private var squelchDelay = DelayLine(delay: 0)
    private var deemphL = Deemphasis(tau: 0, sampleRate: 48_000)
    private var deemphR = Deemphasis(tau: 0, sampleRate: 48_000)
    private var squelchOpen = false
    private var squelchHang: Double = 0
    private var squelchGain: Float = 0
    private var envM2: Double = 0
    private var envM4: Double = 0
    private var snrDB: Float = -20

    // Work buffers.
    private var bufI: [Float] = []
    private var bufQ: [Float] = []
    private var demod: [Float] = []
    private var mags: [Float] = []
    /// Audio of the last `process` call (squelched, before volume).
    private(set) var left: [Float] = []
    private(set) var right: [Float] = []

    private(set) var status = ReceiverStatus()

    /// Forget the current station's RDS data (call after retuning). Thread-safe.
    func resetRDS() {
        resetLock.withLock { rdsResetPending = true }
    }

    /// Forces a full rebuild on the next block (call when the source restarts or the VFO is switched off).
    func reset() {
        built = false
        status = ReceiverStatus()
    }

    // MARK: Building

    private func rebuild(_ c: ReceiverConfig, _ g: DSPConfig, previous: (ReceiverConfig, DSPConfig)?) {
        let structural = previous == nil || previous!.1.sampleRate != g.sampleRate || previous!.0.mode != c.mode
        if structural {
            rates = DSPEngine.rates(for: g.sampleRate)
            let fs = g.sampleRate
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
            dcBlock = DCBlocker(cutoff: 40, sampleRate: ra)
            nfmAudio = NFMAudio(sampleRate: ra)
            rade = c.mode.radeVersion.map { RADEDecoder(rate: ra, version: $0) }
            squelchDelay = DelayLine(delay: c.mode == .nfm ? Int(0.02 * ra) : 0)
            mixer = Mixer()
            cwMixer = Mixer()
            envM2 = 0
            envM4 = 0
            snrDB = -20
            // Fade in the new chain's audio (through the squelch fade) so its first samples don't click.
            squelchGain = 0
        }
        if structural || previous!.0.bandwidth != c.bandwidth || previous!.0.radeLSB != c.radeLSB {
            buildChannelFilter(c)
        }
        if structural {
            notch = AutoNotch(sampleRate: rates.audioRate)
        } else if previous!.0.autoNotch != c.autoNotch {
            notch.reset()
        }
        if structural || previous!.1.deemphasis != g.deemphasis {
            let tau = (c.mode == .wfm) ? g.deemphasis : 0
            deemphL = Deemphasis(tau: tau, sampleRate: rates.audioRate)
            deemphR = Deemphasis(tau: tau, sampleRate: rates.audioRate)
        }
    }

    private func buildChannelFilter(_ c: ReceiverConfig) {
        let range = c.mode.bandwidthRange
        if c.mode == .wfm {
            let r1 = rates.rate1
            let bw = min(max(c.bandwidth, range.lowerBound), min(range.upperBound, 0.92 * r1))
            channel = FFTFilter(realTaps: FIR.lowpass(cutoff: bw / 2 / r1, transition: 25_000 / r1, maxTaps: 511))
        } else {
            let ra = rates.audioRate
            let bw = min(max(c.bandwidth, range.lowerBound), 0.84 * ra)
            let edges = c.mode.filterEdges(bandwidth: bw, lsb: c.radeLSB)
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

    /// Demodulates one block of DC-corrected I/Q (left untouched). Returns the number of audio samples now in
    /// `left` and `right`.
    func process(i inI: UnsafePointer<Float>, q inQ: UnsafePointer<Float>, count n: Int,
                 config c: ReceiverConfig, global g: DSPConfig) -> Int {
        if !built {
            rebuild(c, g, previous: nil)
            built = true
        } else if c != cfg || g.sampleRate != global.sampleRate || g.deemphasis != global.deemphasis {
            rebuild(c, g, previous: (cfg, global))
        }
        cfg = c
        global = g
        status.inBand = true

        ensure(&bufI, n)
        ensure(&bufQ, n)
        bufI.withUnsafeMutableBufferPointer { ip in
            bufQ.withUnsafeMutableBufferPointer { qp in
                let i = ip.baseAddress!, q = qp.baseAddress!
                i.update(from: inI, count: n)
                q.update(from: inQ, count: n)
                mixer.mix(re: i, im: q, count: n, frequency: c.vfoOffset, sampleRate: g.sampleRate)
            }
        }

        let n1 = bufI.withUnsafeBufferPointer { i in
            bufQ.withUnsafeBufferPointer { q in stage1.process(i: i.baseAddress!, q: q.baseAddress!, count: n) }
        }
        guard n1 > 0 else { return 0 }

        let audioCount: Int
        var levelDB: Float = -150
        if c.mode == .wfm {
            let nc = stage1.outI.withUnsafeBufferPointer { i in
                stage1.outQ.withUnsafeBufferPointer { q in channel.process(re: i.baseAddress!, im: q.baseAddress!, count: n1) }
            }
            guard nc > 0 else { return 0 }
            levelDB = channelPower(nc)
            updateSNR(from: 0, count: nc, rate: rates.rate1)
            ensure(&demod, nc)
            let gain = Float(rates.rate1 / (2 * .pi * 75_000))
            channel.outRe.withUnsafeBufferPointer { re in
                channel.outIm.withUnsafeBufferPointer { im in
                    fm.process(re: re.baseAddress!, im: im.baseAddress!, count: nc, gain: gain, output: &demod)
                }
            }
            if resetLock.withLock({ let r = rdsResetPending; rdsResetPending = false; return r }) {
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
            guard n2 > 0 else { return 0 }
            let nc = stage2.outI.withUnsafeBufferPointer { i in
                stage2.outQ.withUnsafeBufferPointer { q in channel.process(re: i.baseAddress!, im: q.baseAddress!, count: n2) }
            }
            guard nc > 0 else { return 0 }
            levelDB = channelPower(nc)
            ensure(&left, nc)
            ensure(&right, nc)
            demodulateNarrow(nc, c, g)
            if c.mode == .nfm {
                // Delay the audio, not the squelch decision, so the mute lands before the noise burst
                // that the SNR estimate takes a few milliseconds to notice.
                left.withUnsafeBufferPointer { squelchDelay.process($0.baseAddress!, count: nc) }
                left.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: squelchDelay.output, count: nc) }
            }
            audioCount = nc
            right.withUnsafeMutableBufferPointer { r in left.withUnsafeBufferPointer { r.baseAddress!.update(from: $0.baseAddress!, count: nc) } }
        }

        // Squelch. NFM decides every 5 ms (its channel samples run at the audio rate), so the noise burst at
        // the end of a transmission is cut within a few milliseconds; the rest decide once per block.
        // Transitions fade over 5 ms to avoid clicks.
        let isFM = c.mode == .wfm || c.mode == .nfm
        let fadeStep = Float(1 / (0.005 * rates.audioRate))
        if c.mode == .nfm {
            let step = max(1, Int(0.005 * rates.audioRate))
            var start = 0
            while start < audioCount {
                let len = min(step, audioCount - start)
                updateSNR(from: start, count: len, rate: rates.audioRate)
                let audible = updateSquelch(c, levelDB: levelDB, duration: Double(len) / rates.audioRate)
                applySquelchGain(from: start, count: len, target: audible ? 1 : 0, step: fadeStep)
                start += len
            }
        } else {
            let audible = updateSquelch(c, levelDB: levelDB, duration: Double(audioCount) / rates.audioRate)
            applySquelchGain(from: 0, count: audioCount, target: audible ? 1 : 0, step: fadeStep)
        }

        status.levelDB = levelDB
        status.squelchOpen = squelchOpen
        status.snrDB = isFM ? snrDB : nil
        status.stereoLocked = (stereo?.locked ?? false) && c.mode == .wfm
        status.agcGainDB = agc.currentGainDB
        status.rds = (c.mode == .wfm && c.rds ? rds?.info : nil) ?? RDSInfo()
        status.rade = rade?.status
        return audioCount
    }

    /// The VFO is outside the captured band: no audio, no signal.
    func markOutOfBand() {
        if status.inBand {
            status = ReceiverStatus()
            status.inBand = false
            squelchGain = 0
            rds?.reset()
        }
    }

    private func channelPower(_ n: Int) -> Float {
        var pr: Float = 0, pi: Float = 0
        vDSP_measqv(channel.outRe, 1, &pr, vDSP_Length(n))
        vDSP_measqv(channel.outIm, 1, &pi, vDSP_Length(n))
        return 10 * log10f(max(pr + pi, 1e-15))
    }

    /// Updates `squelchOpen` and returns whether audio should pass. Level squelch: 3 dB hysteresis. Auto (FM):
    /// open above 6 dB C/N. Below 3 dB the audio mutes at once, while the squelch itself stays open for a short
    /// hang so a brief fade doesn't close it; audio returns as soon as the signal does.
    private func updateSquelch(_ c: ReceiverConfig, levelDB: Float, duration: Double) -> Bool {
        guard c.squelchEnabled else {
            squelchOpen = true
            return true
        }
        if c.squelchAuto && (c.mode == .wfm || c.mode == .nfm) {
            if snrDB > 6 {
                squelchOpen = true
                squelchHang = 0.15
                return true
            }
            if snrDB < 3 {
                squelchHang -= duration
                if squelchHang <= 0 { squelchOpen = false }
                return false
            }
            return squelchOpen
        }
        squelchOpen = squelchOpen ? levelDB > c.squelchLevel - 3 : levelDB > c.squelchLevel
        return squelchOpen
    }

    private func applySquelchGain(from start: Int, count: Int, target: Float, step: Float) {
        var g = squelchGain
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                if g == target {
                    if target == 0 {
                        (l.baseAddress! + start).update(repeating: 0, count: count)
                        (r.baseAddress! + start).update(repeating: 0, count: count)
                    }
                    return
                }
                for k in start..<(start + count) {
                    g = target > g ? min(target, g + step) : max(target, g - step)
                    l[k] *= g
                    r[k] *= g
                }
            }
        }
        squelchGain = g
    }

    /// Carrier-to-noise estimate from the envelope moments of the channel output (M2M4 estimator).
    /// An FM carrier has a constant envelope, noise a Rayleigh one, so this works at any signal level.
    private func updateSNR(from start: Int, count n: Int, rate: Double) {
        ensure(&mags, n)
        channel.outRe.withUnsafeBufferPointer { rp in
            channel.outIm.withUnsafeBufferPointer { ip in
                var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: rp.baseAddress! + start),
                                            imagp: UnsafeMutablePointer(mutating: ip.baseAddress! + start))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n))
            }
        }
        var m2: Float = 0, m4: Float = 0
        vDSP_meanv(mags, 1, &m2, vDSP_Length(n))
        vDSP_measqv(mags, 1, &m4, vDSP_Length(n))
        // Average the moments over ~30 ms; they are normalised by M2² below, so level changes cancel.
        let a = envM2 == 0 ? 1 : 1 - exp(-Double(n) / rate / 0.03)
        envM2 += a * (Double(m2) - envM2)
        envM4 += a * (Double(m4) - envM4)
        guard envM2 > 0 else { return }
        let s = (max(0, 2 * envM2 * envM2 - envM4)).squareRoot()
        let noise = max(envM2 - s, 1e-12)
        snrDB = Float(10 * log10(max(s / noise, 1e-3)))
    }

    private func demodulateNarrow(_ n: Int, _ c: ReceiverConfig, _ g: DSPConfig) {
        let ra = rates.audioRate
        let useNotch = c.autoNotch && c.mode.supportsAutoNotch
        let edges = c.mode.filterEdges(bandwidth: c.bandwidth, lsb: c.radeLSB)
        let notchMax = max(abs(edges.lo), abs(edges.hi))
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
                        if useNotch { notch.process(out, count: n, maxFrequency: notchMax) }
                        agc.process(out, count: n, mode: c.agcMode, manualGainDB: c.afGainDB)
                    case .nfm:
                        // Full scale at the channel's nominal peak deviation (bandwidth / 5: 2.5 kHz in a
                        // 12.5 kHz channel, 5 kHz in 25 kHz).
                        let deviation = c.bandwidth / 5
                        fm.process(re: re, im: im, count: n, gain: Float(ra / (2 * .pi * deviation)), output: out)
                        nfmAudio.process(out, count: n)
                    case .usb, .lsb, .dsb:
                        out.update(from: re, count: n)
                        if useNotch { notch.process(out, count: n, maxFrequency: notchMax) }
                        agc.process(out, count: n, mode: c.agcMode, manualGainDB: c.afGainDB)
                    case .cw:
                        // Shift the carrier up to the CW pitch, then take the real part.
                        let mre = UnsafeMutablePointer(mutating: re), mim = UnsafeMutablePointer(mutating: im)
                        cwMixer.mix(re: mre, im: mim, count: n, frequency: -g.cwPitch, sampleRate: ra)
                        out.update(from: re, count: n)
                        agc.process(out, count: n, mode: c.agcMode, manualGainDB: c.afGainDB)
                    case .rade, .radeV2:
                        // The vocoder's output has a fixed level, so no AGC.
                        rade?.process(re: re, im: im, count: n, lsb: c.radeLSB, output: out)
                    case .wfm:
                        break
                    }
                }
            }
        }
    }
}
