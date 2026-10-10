import XCTest
import Accelerate
@testable import SDRCore

final class RADETests: XCTestCase {
    private func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    /// 12 s of a real RADE V1 over as received in USB (8 kHz mono): in sync from ~0.6 s, end of over at ~10.6 s
    /// (callsign VK5KVA), then no signal. From the rade_c repository (FDV_offair.wav).
    private func loadFixture() throws -> [Float] {
        let url = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Fixtures/rade_v1_offair_8k.wav"))
        let data = try Data(contentsOf: url)
        // 16-bit mono PCM with a plain 44-byte header.
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        return data[44...].withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
        }
    }

    private func upsample(_ x: [Float], from inRate: Double, to outRate: Double) -> [Float] {
        let r = Resampler(inputRate: inRate, outputRate: outRate, passband: 3_000, stopband: 4_000)
        let n = x.withUnsafeBufferPointer { r.process($0.baseAddress!, count: x.count) }
        return Array(r.output[0..<n])
    }

    func testResamplerKeepsToneAndRate() {
        for (inRate, outRate, tone) in [(48_000.0, 8_000.0, 1_000.0), (16_000, 51_200, 1_500), (16_000, 48_000, 6_500)] {
            let n = Int(inRate)
            let x = (0..<n).map { Float(sin(2 * .pi * tone * Double($0) / inRate)) }
            let r = Resampler(inputRate: inRate, outputRate: outRate, passband: min(inRate, outRate) * 0.4,
                              stopband: min(inRate, outRate) * 0.5)
            // Odd block sizes, like the engine delivers.
            var y: [Float] = []
            var pos = 0
            while pos < n {
                let m = min(n - pos, Int.random(in: 1...700))
                let k = x.withUnsafeBufferPointer { r.process($0.baseAddress! + pos, count: m) }
                y += r.output[0..<k]
                pos += m
            }
            XCTAssertEqual(Double(y.count), outRate, accuracy: outRate / inRate + 1, "\(inRate) → \(outRate)")
            let tail = y[(y.count / 4)...]
            XCTAssertEqual(rms(tail), Float(0.5.squareRoot()), accuracy: 0.01, "\(inRate) → \(outRate)")
            var crossings = 0
            for (a, b) in zip(tail, tail.dropFirst()) where (a < 0) != (b < 0) { crossings += 1 }
            XCTAssertEqual(Double(crossings) / 2 / (Double(tail.count) / outRate), tone, accuracy: 3, "\(inRate) → \(outRate)")
        }
    }

    func testDecodesOffAirRecording() throws {
        try XCTSkipUnless(RADEDecoder.isAvailable, "RADE not built (scripts/fetch-rade.sh)")
        let rate = 48_000.0
        let x = upsample(try loadFixture(), from: 8_000, to: rate)
        let zeros = [Float](repeating: 0, count: x.count)
        let decoder = RADEDecoder(rate: rate)
        var speech = [Float](repeating: 0, count: x.count)
        var everSynced = false
        var bestSNR: Float = -100
        let chunk = 960
        var pos = 0
        while pos < x.count {
            let n = min(chunk, x.count - pos)
            x.withUnsafeBufferPointer { xp in
                zeros.withUnsafeBufferPointer { zp in
                    speech.withUnsafeMutableBufferPointer { sp in
                        decoder.process(re: xp.baseAddress! + pos, im: zp.baseAddress! + pos, count: n, output: sp.baseAddress! + pos)
                    }
                }
            }
            if decoder.status.sync {
                everSynced = true
                bestSNR = max(bestSNR, decoder.status.snrDB)
                XCTAssertEqual(decoder.status.frequencyOffset, 0, accuracy: 10)
            }
            pos += n
        }
        XCTAssertTrue(everSynced)
        XCTAssertGreaterThan(bestSNR, 15)
        // The over ends with an end-of-over frame carrying the operator's callsign.
        XCTAssertEqual(decoder.status.callsign, "VK5KVA")
        XCTAssertEqual(decoder.status.callsignCount, 1)
        let r = Int(rate)
        let during = rms(speech[(2 * r)..<(9 * r)])
        XCTAssertGreaterThan(during, 0.02, "speech while in sync")
        XCTAssertFalse(decoder.status.sync, "end of over")
        XCTAssertLessThan(rms(speech[(11 * r)...]), during * 0.01, "silence after the over")
    }

    func testSidebandConvention() {
        XCTAssertTrue(RADESideband.conventionallyLSB(at: 3_625_000))
        XCTAssertTrue(RADESideband.conventionallyLSB(at: 7_177_000))
        XCTAssertFalse(RADESideband.conventionallyLSB(at: 5_363_000), "60 m is USB")
        XCTAssertFalse(RADESideband.conventionallyLSB(at: 14_236_000))
        XCTAssertFalse(RADESideband.conventionallyLSB(at: 10_000_000))
        XCTAssertTrue(RADESideband.lsb.isLSB(at: 14_236_000))
        XCTAssertFalse(RADESideband.usb.isLSB(at: 7_177_000))
    }

    /// The over 30 kHz above the tuner centre as 240 kHz I/Q, in USB or (mirrored) in LSB.
    private func makeIQ(lsb: Bool) throws -> [Int16] {
        let fs = 240_000.0
        let vfo = 30_000.0
        // Analytic version of the real recording (keep 0.1–3.6 kHz, drop the negative frequencies).
        let audio = try loadFixture()
        let taps = FIR.complexBandpass(lo: 100 / 8_000, hi: 3_600 / 8_000, transition: 200 / 8_000)
        let filter = FFTFilter(tapsRe: taps.re, tapsIm: taps.im)
        let zeros = [Float](repeating: 0, count: audio.count)
        let n8 = audio.withUnsafeBufferPointer { a in zeros.withUnsafeBufferPointer { filter.process(re: a.baseAddress!, im: $0.baseAddress!, count: audio.count) } }
        let i = upsample(Array(filter.outRe[0..<n8]), from: 8_000, to: fs)
        var q = upsample(Array(filter.outIm[0..<n8]), from: 8_000, to: fs)
        if lsb { q = q.map { -$0 } }
        var iq = [Int16](repeating: 0, count: 2 * i.count)
        for k in 0..<i.count {
            let ph = 2 * .pi * vfo * Double(k) / fs
            let c = Float(cos(ph)), s = Float(sin(ph))
            let re = 0.05 * (i[k] * c - q[k] * s) + Float.random(in: -0.002...0.002)
            let im = 0.05 * (i[k] * s + q[k] * c) + Float.random(in: -0.002...0.002)
            iq[2 * k] = Int16(re * 32768)
            iq[2 * k + 1] = Int16(im * 32768)
        }
        return iq
    }

    /// Runs the engine in RADE mode; returns whether it synced and the audio.
    private func receive(_ iq: [Int16], lsb: Bool) -> (synced: Bool, audio: [Float], rate: Double, callsign: String?) {
        let engine = DSPEngine()
        var c = DSPConfig()
        c.sampleRate = 240_000
        c.vfoOffset = 30_000
        c.mode = .rade
        c.radeLSB = lsb
        c.bandwidth = DemodMode.rade.defaultBandwidth
        c.volume = 1
        engine.config = c
        var audioOut: [Float] = []
        var tmpL = [Float](repeating: 0, count: 256), tmpR = tmpL
        var everSynced = false
        let chunk = 2 * 24_000
        var pos = 0
        while pos < iq.count {
            let end = min(iq.count, pos + chunk)
            iq.withUnsafeBufferPointer { engine.process(.s16(UnsafeBufferPointer(rebasing: $0[pos..<end]))) }
            pos = end
            if engine.status.rade?.sync == true { everSynced = true }
            while engine.audioRing.latency > 0.09 {
                engine.audioRing.read(left: &tmpL, right: &tmpR, count: 256)
                audioOut += tmpL
            }
        }
        return (everSynced, audioOut, engine.status.audioRate, engine.status.rade?.callsign)
    }

    /// The whole chain, in both sidebands. The wrong sideband sees a mirrored signal and must not sync.
    func testEngineRADEEndToEnd() throws {
        try XCTSkipUnless(RADEDecoder.isAvailable, "RADE not built (scripts/fetch-rade.sh)")
        for lsb in [false, true] {
            let iq = try makeIQ(lsb: lsb)
            let right = receive(iq, lsb: lsb)
            XCTAssertTrue(right.synced, lsb ? "LSB" : "USB")
            XCTAssertEqual(right.callsign, "VK5KVA", lsb ? "LSB" : "USB")
            let r = Int(right.rate)
            XCTAssertGreaterThan(rms(right.audio[(2 * r)..<(9 * r)]), 0.02, lsb ? "LSB" : "USB")
            XCTAssertFalse(receive(iq, lsb: !lsb).synced, lsb ? "LSB signal in USB" : "USB signal in LSB")
        }
    }
}
