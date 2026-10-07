import XCTest
import Accelerate
@testable import SDRCore

final class DSPTests: XCTestCase {
    // MARK: helpers

    private func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    /// Dominant frequency by zero-crossing count.
    private func zeroCrossingFrequency(_ x: ArraySlice<Float>, sampleRate: Double) -> Double {
        var crossings = 0
        var prev = x.first ?? 0
        for v in x.dropFirst() {
            if (prev < 0) != (v < 0) { crossings += 1 }
            prev = v
        }
        return Double(crossings) / 2 / (Double(x.count) / sampleRate)
    }

    /// Generates u8 I/Q with a complex baseband signal function evaluated at time t (seconds).
    private func makeIQ(sampleRate: Double, seconds: Double, noise: Float = 0.002,
                        _ signal: (Int, Double) -> (Float, Float)) -> [UInt8] {
        let n = Int(sampleRate * seconds)
        var out = [UInt8](repeating: 127, count: 2 * n)
        for k in 0..<n {
            let (i, q) = signal(k, Double(k) / sampleRate)
            let ni = Float.random(in: -noise...noise), nq = Float.random(in: -noise...noise)
            out[2 * k] = UInt8(max(0, min(255, (i + ni) * 127.5 + 127.5)))
            out[2 * k + 1] = UInt8(max(0, min(255, (q + nq) * 127.5 + 127.5)))
        }
        return out
    }

    private func runEngine(_ engine: DSPEngine, iq: [UInt8], chunk: Int = 131_072) -> (left: [Float], right: [Float]) {
        var l: [Float] = []
        var r: [Float] = []
        var tmpL = [Float](repeating: 0, count: 4096)
        var tmpR = tmpL
        var offset = 0
        while offset < iq.count {
            let end = min(iq.count, offset + chunk)
            iq.withUnsafeBufferPointer { engine.process(UnsafeBufferPointer(rebasing: $0[offset..<end])) }
            offset = end
            // Drain like the audio callback would. Stay above the ring's 80 ms priming threshold,
            // below it the ring returns silence without consuming.
            var guardCount = 0
            while engine.audioRing.latency > 0.09, guardCount < 10_000 {
                guardCount += 1
                engine.audioRing.read(left: &tmpL, right: &tmpR, count: 256)
                l += tmpL[0..<256]
                r += tmpR[0..<256]
            }
        }
        return (l, r)
    }

    // MARK: tests

    func testLowpassHasUnityDCGain() {
        let taps = FIR.lowpass(cutoff: 0.1, transition: 0.05)
        XCTAssertEqual(taps.reduce(0, +), 1, accuracy: 1e-4)
        XCTAssertEqual(taps.count % 2, 1)
    }

    func testRatesPlan() {
        let r = DSPEngine.rates(for: 2_400_000)
        XCTAssertEqual(r.decim1, 10)
        XCTAssertEqual(r.rate1, 240_000)
        XCTAssertEqual(r.audioRate, 48_000)
        let r2 = DSPEngine.rates(for: 2_048_000)
        XCTAssertEqual(r2.audioRate, 51_200)
    }

    func testFFTFilterMatchesDirectConvolution() {
        let taps = FIR.complexBandpass(lo: 0.01, hi: 0.1, transition: 0.02)
        let filter = FFTFilter(tapsRe: taps.re, tapsIm: taps.im)
        let n = 10_000
        let xr = (0..<n).map { _ in Float.random(in: -1...1) }
        let xi = (0..<n).map { _ in Float.random(in: -1...1) }
        let produced = filter.process(re: xr, im: xi, count: n)
        XCTAssertGreaterThan(produced, 5_000)
        // Direct complex convolution at a few points.
        for k in [taps.re.count + 10, produced / 2, produced - 1] {
            var sr: Float = 0, si: Float = 0
            for j in 0..<taps.re.count where k - j >= 0 {
                sr += taps.re[j] * xr[k - j] - taps.im[j] * xi[k - j]
                si += taps.re[j] * xi[k - j] + taps.im[j] * xr[k - j]
            }
            XCTAssertEqual(filter.outRe[k], sr, accuracy: 1e-3)
            XCTAssertEqual(filter.outIm[k], si, accuracy: 1e-3)
        }
    }

    func testFMDemodulatorRecoversTone() {
        let fs = 48_000.0
        let n = 48_000
        var re = [Float](repeating: 0, count: n), im = re
        var phase = 0.0
        for k in 0..<n {
            let m = sin(2 * .pi * 1_000 * Double(k) / fs)
            phase += 2 * .pi * 5_000 * m / fs
            re[k] = Float(cos(phase))
            im[k] = Float(sin(phase))
        }
        var out = [Float](repeating: 0, count: n)
        FMDemodulator().process(re: re, im: im, count: n, gain: Float(fs / (2 * .pi * 5_000)), output: &out)
        XCTAssertEqual(Double(out[1000...].max()!), 1, accuracy: 0.02)
        XCTAssertEqual(zeroCrossingFrequency(out[1000...], sampleRate: fs), 1_000, accuracy: 5)
    }

    func testStereoDecoderSeparatesChannels() {
        let fs = 240_000.0
        let n = Int(fs)
        var mpx = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let t = Double(k) / fs
            let l = sin(2 * .pi * 1_000 * t)
            let r = 0.0
            let pilot = sin(2 * .pi * 19_000 * t)
            mpx[k] = Float(0.45 * (l + r) + 0.45 * (l - r) * sin(2 * .pi * 38_000 * t) + 0.1 * pilot)
        }
        let dec = StereoDecoder(inputRate: fs, decimation: 5)
        var left: [Float] = [], right: [Float] = []
        var offset = 0
        while offset < n {
            let c = min(8192, n - offset)
            let m = mpx.withUnsafeBufferPointer { dec.process(mpx: $0.baseAddress! + offset, count: c, stereoEnabled: true) }
            left += dec.left[0..<m]
            right += dec.right[0..<m]
            offset += c
        }
        XCTAssertTrue(dec.locked, "pilot PLL should lock")
        let tail = left.count / 2
        let lr = rms(left[tail...]), rr = rms(right[tail...])
        XCTAssertGreaterThan(lr, 0.2)
        XCTAssertGreaterThan(20 * log10(lr / max(rr, 1e-6)), 25, "stereo separation in dB")
    }

    func testEngineWFMEndToEnd() {
        let fs = 2_400_000.0
        let offset = 300_000.0
        var phase = 0.0
        let iq = makeIQ(sampleRate: fs, seconds: 1.5) { _, t in
            let m = 0.8 * sin(2 * .pi * 1_000 * t)
            phase += 2 * .pi * (offset + 75_000 * m) / fs
            return (Float(0.4 * cos(phase)), Float(0.4 * sin(phase)))
        }
        let engine = DSPEngine()
        var c = DSPConfig()
        c.sampleRate = fs
        c.vfoOffset = offset
        c.mode = .wfm
        c.bandwidth = 180_000
        c.volume = 1
        c.deemphasis = 0
        engine.config = c
        let (l, r) = runEngine(engine, iq: iq)
        XCTAssertGreaterThan(l.count, 40_000)
        let tail = l[(l.count / 2)...]
        XCTAssertEqual(Double(rms(tail)), 0.8 * 0.7071, accuracy: 0.08)
        XCTAssertEqual(zeroCrossingFrequency(tail, sampleRate: 48_000), 1_000, accuracy: 20)
        XCTAssertEqual(rms(tail), rms(r[(r.count / 2)...]), accuracy: 0.01, "mono signal: L == R")
        XCTAssertGreaterThan(engine.status.levelDB, -15)
    }

    func testEngineUSBProducesAudioTone() {
        let fs = 2_400_000.0
        let vfo = -200_000.0
        let iq = makeIQ(sampleRate: fs, seconds: 1.0) { _, t in
            // Single tone 1.2 kHz above the VFO: USB should give a 1.2 kHz beat.
            let ph = 2 * .pi * (vfo + 1_200) * t
            return (Float(0.05 * cos(ph)), Float(0.05 * sin(ph)))
        }
        let engine = DSPEngine()
        var c = DSPConfig()
        c.sampleRate = fs
        c.vfoOffset = vfo
        c.mode = .usb
        c.bandwidth = 2_700
        c.volume = 1
        engine.config = c
        let (l, _) = runEngine(engine, iq: iq)
        let tail = l[(l.count / 2)...]
        XCTAssertGreaterThan(rms(tail), 0.1)
        XCTAssertEqual(zeroCrossingFrequency(tail, sampleRate: 48_000), 1_200, accuracy: 20)

        // The same tone in LSB mode falls outside the passband.
        let engine2 = DSPEngine()
        c.mode = .lsb
        c.agcMode = .off
        c.afGainDB = 0
        engine2.config = c
        let (l2, _) = runEngine(engine2, iq: iq)
        XCTAssertLessThan(rms(l2[(l2.count / 2)...]), rms(tail) * 0.1)
    }

    func testEngineAMDemodulation() {
        let fs = 1_024_000.0
        let vfo = 150_000.0
        let iq = makeIQ(sampleRate: fs, seconds: 1.0) { _, t in
            let a = 0.1 * (1 + 0.5 * sin(2 * .pi * 700 * t))
            let ph = 2 * .pi * vfo * t
            return (Float(a * cos(ph)), Float(a * sin(ph)))
        }
        let engine = DSPEngine()
        var c = DSPConfig()
        c.sampleRate = fs
        c.vfoOffset = vfo
        c.mode = .am
        c.bandwidth = 8_000
        c.volume = 1
        engine.config = c
        let (l, _) = runEngine(engine, iq: iq)
        let rate = DSPEngine.rates(for: fs).audioRate
        let tail = l[(l.count / 2)...]
        XCTAssertGreaterThan(rms(tail), 0.05)
        XCTAssertEqual(zeroCrossingFrequency(tail, sampleRate: rate), 700, accuracy: 15)
    }

    func testSquelchMutesWeakSignal() {
        let fs = 2_400_000.0
        let iq = makeIQ(sampleRate: fs, seconds: 0.5, noise: 0.01) { _, _ in (0, 0) }
        let engine = DSPEngine()
        var c = DSPConfig()
        c.sampleRate = fs
        c.mode = .nfm
        c.bandwidth = 12_500
        c.vfoOffset = 100_000
        c.volume = 1
        c.squelchEnabled = true
        c.squelchLevel = -20
        engine.config = c
        let (l, _) = runEngine(engine, iq: iq)
        XCTAssertEqual(rms(l[...]), 0)
        XCTAssertFalse(engine.status.squelchOpen)
    }

    /// FM carrier (1 kHz tone, given deviation) plus uniform noise; returns status and audio after the run.
    private func runAutoSquelch(mode: DemodMode, bandwidth: Double, deviation: Double,
                                amplitude: Double, noise: Float) -> (status: DSPStatus, audio: [Float]) {
        let fs = 2_400_000.0
        let offset = 200_000.0
        var phase = 0.0
        let iq = makeIQ(sampleRate: fs, seconds: 0.6, noise: noise) { _, t in
            phase += 2 * .pi * (offset + deviation * sin(2 * .pi * 1_000 * t)) / fs
            return (Float(amplitude * cos(phase)), Float(amplitude * sin(phase)))
        }
        let engine = DSPEngine()
        var c = DSPConfig()
        c.sampleRate = fs
        c.vfoOffset = offset
        c.mode = mode
        c.bandwidth = bandwidth
        c.volume = 1
        c.squelchEnabled = true
        c.squelchAuto = true
        c.squelchLevel = 0  // ignored in auto mode
        engine.config = c
        let (l, _) = runEngine(engine, iq: iq)
        return (engine.status, l)
    }

    func testAutoSquelchClosedOnNoise() {
        for (mode, bw) in [(DemodMode.nfm, 12_500.0), (.wfm, 180_000)] {
            let r = runAutoSquelch(mode: mode, bandwidth: bw, deviation: 0, amplitude: 0, noise: 0.05)
            XCTAssertFalse(r.status.squelchOpen, "\(mode)")
            XCTAssertLessThan(r.status.snrDB ?? 99, 3, "\(mode)")
            XCTAssertEqual(rms(r.audio[...]), 0, "\(mode)")
        }
    }

    func testAutoSquelchOpensOnFMCarrier() {
        // Weak in absolute terms (−40 dBFS) but clean: auto squelch must not depend on level.
        let nfm = runAutoSquelch(mode: .nfm, bandwidth: 12_500, deviation: 2_500, amplitude: 0.01, noise: 0.002)
        XCTAssertTrue(nfm.status.squelchOpen)
        XCTAssertGreaterThan(nfm.status.snrDB ?? 0, 15)
        XCTAssertGreaterThan(rms(nfm.audio[(nfm.audio.count / 2)...]), 0.1)

        // Full-deviation broadcast FM: the channel filter clips sidebands, which must not read as noise.
        let wfm = runAutoSquelch(mode: .wfm, bandwidth: 180_000, deviation: 75_000, amplitude: 0.3, noise: 0.002)
        XCTAssertTrue(wfm.status.squelchOpen)
        XCTAssertGreaterThan(wfm.status.snrDB ?? 0, 12)
    }

    func testSNREstimateIsCalibrated() {
        // Uniform noise ±a per component: complex power 2a²/3 over the full sample rate.
        let fs = 2_400_000.0, bw = 12_500.0, a: Float = 0.1
        let noisePower = 2 * Double(a * a) / 3 * bw / fs
        for target in [0.0, 10.0, 20.0] {
            let amp = (noisePower * pow(10, target / 10)).squareRoot()
            let r = runAutoSquelch(mode: .nfm, bandwidth: bw, deviation: 2_000, amplitude: amp, noise: a)
            XCTAssertEqual(Double(r.status.snrDB ?? -99), target, accuracy: target == 0 ? 4 : 2.5)
        }
    }

    func testSpectrumPeakAtToneFrequency() {
        let fs = 2_400_000.0
        let iq = makeIQ(sampleRate: fs, seconds: 0.2) { _, t in
            let ph = 2 * .pi * 600_000 * t
            return (Float(0.5 * cos(ph)), Float(0.5 * sin(ph)))
        }
        let engine = DSPEngine()
        var c = DSPConfig()
        c.sampleRate = fs
        c.fftSize = 4096
        c.averaging = 0
        engine.config = c
        _ = runEngine(engine, iq: iq)
        engine.spectrum.withLatest { spectrum, _, _ in
            XCTAssertEqual(spectrum.count, 4096)
            let peakBin = spectrum.indices.max { spectrum[$0] < spectrum[$1] }!
            let freq = (Double(peakBin) - 2048) * fs / 4096
            XCTAssertEqual(freq, 600_000, accuracy: fs / 4096)
            XCTAssertEqual(Double(spectrum[peakBin]), 20 * log10(0.5), accuracy: 1.5)
        }
        XCTAssertFalse(engine.spectrum.drainLines().isEmpty)
    }

    func testEngineIsFasterThanRealTime() {
        let fs = 2_400_000.0
        var phase = 0.0
        let iq = makeIQ(sampleRate: fs, seconds: 1.0) { _, t in
            phase += 2 * .pi * (250_000 + 50_000 * sin(2 * .pi * 1_000 * t)) / fs
            return (Float(0.3 * cos(phase)), Float(0.3 * sin(phase)))
        }
        for mode in [DemodMode.wfm, .usb, .nfm] {
            let engine = DSPEngine()
            var c = DSPConfig()
            c.sampleRate = fs
            c.mode = mode
            c.bandwidth = mode.defaultBandwidth
            c.vfoOffset = 250_000
            c.fftSize = 16384
            engine.config = c
            let start = Date()
            _ = runEngine(engine, iq: iq)
            let elapsed = Date().timeIntervalSince(start)
            print("1 s of 2.4 MS/s \(mode.rawValue): \(String(format: "%.0f", elapsed * 1000)) ms")
            XCTAssertLessThan(elapsed, 1.0)
        }
    }
}
