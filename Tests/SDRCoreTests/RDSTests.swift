import XCTest
@testable import SDRCore

final class RDSTests: XCTestCase {
    func testValidBlocksHaveOffsetSyndromes() {
        for offset in RDS.Offset.allCases {
            for data: UInt16 in [0, 0x1234, 0xFFFF, 0x8201] {
                let block = RDS.block(data, offset)
                XCTAssertEqual(RDS.syndrome(block, length: 26), RDS.syndromes[offset.rawValue])
            }
        }
        XCTAssertEqual(Set(RDS.syndromes).count, 5, "offset syndromes must be distinct")
    }

    func testShortErrorBurstsAreCorrected() {
        let block = RDS.block(0x83C6, .a)
        XCTAssertEqual(RDS.correct(block ^ (1 << 20), .a), 0x83C6, "single bit")
        XCTAssertEqual(RDS.correct(block ^ (0b11 << 13), .a), 0x83C6, "2-bit burst")
        XCTAssertEqual(RDS.correct(block ^ (0b11 << 2), .a), 0x83C6, "burst in checkword")
        XCTAssertNil(RDS.correct(block ^ (0b10001 << 8), .a), "longer bursts are not repaired")
    }

    func testParserDecodesGroupsFromEncoder() {
        let bits = RDSEncoder.bitstream(pi: 0x8201, ps: "KYMARA", radioText: "Hello RDS", pty: 10)
        // Undo the differential coding and cut into blocks.
        var prev = false
        var raw: [Bool] = []
        for b in bits { raw.append(b != prev); prev = b }
        let parser = RDSParser()
        var i = 0
        while i + 104 <= raw.count {
            var blocks: [UInt16?] = []
            for k in 0..<4 {
                var v: UInt32 = 0
                for bit in raw[(i + 26 * k)..<(i + 26 * k + 26)] { v = v << 1 | (bit ? 1 : 0) }
                blocks.append(UInt16(v >> 10))
            }
            parser.handle(blocks)
            i += 104
        }
        XCTAssertEqual(parser.info.pi, 0x8201)
        XCTAssertEqual(parser.info.programService, "KYMARA  ")
        XCTAssertEqual(parser.info.radioText, "Hello RDS")
        XCTAssertEqual(parser.info.ptyName, "Pop Music")
        XCTAssertTrue(parser.info.trafficProgram)
    }

    func testClockTimeGroup() {
        // 2026-10-07 14:35 UTC, +2 h → MJD 61320.
        let parser = RDSParser()
        let mjd = 61320
        let b: UInt16 = 4 << 12 | UInt16(mjd >> 15)
        let c = UInt16((mjd & 0x7FFF) << 1) | UInt16(14 >> 4)
        let d = UInt16((14 & 0xF) << 12) | UInt16(35 << 6) | 4
        parser.handle([0x8201, b, c, d])
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: parser.info.clockTime!)
        XCTAssertEqual([comps.year, comps.month, comps.day, comps.hour, comps.minute], [2026, 10, 7, 14, 35])
        XCTAssertEqual(parser.info.clockOffsetMinutes, 120)
    }

    /// Full DSP path: RDS on a 57 kHz subcarrier with arbitrary phase, plus pilot, audio and noise.
    func testDecoderRecoversStationFromMPX() {
        let fs = 240_000.0
        let bits = RDSEncoder.bitstream(pi: 0x8201, ps: "KYMARA", radioText: "Native macOS SDR receiver", pty: 10)
        let seconds = 4.5
        let n = Int(fs * seconds)
        var mpx = [Float](repeating: 0, count: n)
        let carrierPhase = 1.1
        let clockOffset = 0.37 // bits; arbitrary symbol timing
        for k in 0..<n {
            let t = Double(k) / fs
            let pos = t * RDS.bitRate + clockOffset
            let idx = Int(pos) % bits.count
            let frac = pos - floor(pos)
            let symbol = (bits[idx] ? 1.0 : -1.0) * sin(2 * .pi * frac)
            let rds = 0.05 * symbol * cos(2 * .pi * 57_000 * t + carrierPhase)
            let pilot = 0.1 * sin(2 * .pi * 19_000 * t)
            let audio = 0.4 * sin(2 * .pi * 1_000 * t)
            mpx[k] = Float(rds + pilot + audio + Double.random(in: -0.02...0.02))
        }
        let decoder = RDSDecoder(inputRate: fs)
        var offset = 0
        while offset < n {
            let c = min(6_000, n - offset)
            mpx.withUnsafeBufferPointer { decoder.process(mpx: $0.baseAddress! + offset, count: c) }
            offset += c
        }
        let info = decoder.info
        XCTAssertTrue(info.synced)
        XCTAssertEqual(info.piHex, "8201")
        XCTAssertEqual(info.programService, "KYMARA  ")
        XCTAssertEqual(info.radioText, "Native macOS SDR receiver")
        XCTAssertLessThan(info.blockErrorRate, 0.1)
    }
}

final class DemoRDSTests: XCTestCase {
    func testDemoStationCarriesRDS() throws {
        let src = DemoSource()
        let engine = DSPEngine()
        var c = DSPConfig()
        c.sampleRate = 2_400_000
        c.mode = .wfm
        c.vfoOffset = 300_000
        engine.config = c
        try src.start(sampleRate: 2_400_000, centerFrequency: 99_700_000) { engine.process($0) }
        var info = RDSInfo()
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.1)
            info = engine.status.rds
            if info.trimmedProgramService == "KYMARA" { break }
        }
        src.stop()
        XCTAssertEqual(info.piHex, "8201")
        XCTAssertEqual(info.programService, "KYMARA  ")
    }
}
