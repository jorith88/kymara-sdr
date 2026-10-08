import XCTest
@testable import SDRCore

final class SDRplayTests: XCTestCase {
    func testRatePlansAreValid() {
        let bandwidths: Set<Int32> = [200, 300, 600, 1536, 5000, 6000, 7000, 8000]
        for mode in SDRplayConfig.IFMode.allCases {
            for rate in SDRplayRatePlan.outputRates {
                let p = SDRplayRatePlan.plan(outputRate: rate, ifMode: mode)
                XCTAssert((2_000_000...10_660_000).contains(p.fsHz), "fs \(p.fsHz) for \(rate) \(mode)")
                XCTAssert([1, 2, 4, 8, 16, 32].contains(p.decimation))
                XCTAssert(bandwidths.contains(p.bwKHz))
                XCTAssert([0, 1620, 2048].contains(p.ifKHz))
                // The output rate is what falls out of the plan.
                let out: Double
                switch p.ifKHz {
                case 1620: out = 2_000_000 / Double(p.decimation)
                case 2048: out = 2_048_000 / Double(p.decimation)
                default: out = p.fsHz / Double(p.decimation)
                }
                XCTAssertEqual(out, rate, "\(rate) \(mode)")
                if p.ifKHz == 0 { XCTAssertLessThanOrEqual(Double(p.bwKHz) * 1000, rate) }
            }
        }
    }

    func testIFModeSelection() {
        XCTAssertTrue(SDRplayRatePlan.plan(outputRate: 2_000_000, ifMode: .auto).isLowIF)
        XCTAssertTrue(SDRplayRatePlan.plan(outputRate: 250_000, ifMode: .lowIF).isLowIF)
        XCTAssertFalse(SDRplayRatePlan.plan(outputRate: 2_000_000, ifMode: .zeroIF).isLowIF)
        // Low IF is only possible up to 2.048 MS/s.
        XCTAssertFalse(SDRplayRatePlan.plan(outputRate: 6_000_000, ifMode: .lowIF).isLowIF)
        XCTAssertEqual(SDRplayRatePlan.plan(outputRate: 500_000, ifMode: .zeroIF),
                       SDRplayRatePlan(fsHz: 2_000_000, ifKHz: 0, bwKHz: 300, decimation: 4))
    }

    func testLNAStateCounts() {
        XCTAssertEqual(SDRplayModel(hwVer: 1), .rsp1)
        XCTAssertEqual(SDRplayModel.rsp1.lnaStateCount(frequency: 100e6, antenna: .a), 4)
        XCTAssertEqual(SDRplayModel.rsp1.lnaStateCount(frequency: 1_500e6, antenna: .a), 4)
        XCTAssertEqual(SDRplayModel(hwVer: 255).lnaStateCount(frequency: 7e6, antenna: .a), 7)
        XCTAssertEqual(SDRplayModel.rsp1a.lnaStateCount(frequency: 100e6, antenna: .a), 10)
        XCTAssertEqual(SDRplayModel.rsp1a.lnaStateCount(frequency: 1_300e6, antenna: .a), 9)
        XCTAssertEqual(SDRplayModel.rsp2.lnaStateCount(frequency: 7e6, antenna: .hiZ), 5)
        XCTAssertEqual(SDRplayModel.rsp2.lnaStateCount(frequency: 433e6, antenna: .a), 6)
        XCTAssertEqual(SDRplayModel.rspDuo.lnaStateCount(frequency: 100e6, antenna: .b), 10)
        XCTAssertEqual(SDRplayModel.rspDx.lnaStateCount(frequency: 100e6, antenna: .a), 27)
        XCTAssertEqual(SDRplayModel(hwVer: 7).lnaStateCount(frequency: 300e6, antenna: .a), 28)
        XCTAssertTrue(SDRplayModel.rsp1.antennas.isEmpty)
        XCTAssertFalse(SDRplayModel.rsp1.hasBiasT)
    }

    func testConfigDecodesPartialData() throws {
        let json = #"{"lnaState": 3, "ifMode": "lowIF", "antenna": "bogus"}"#
        let c = try JSONDecoder().decode(SDRplayConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.lnaState, 3)
        XCTAssertEqual(c.ifMode, .lowIF)
        XCTAssertEqual(c.antenna, .a)
        XCTAssertEqual(c.ifGainReduction, SDRplayConfig().ifGainReduction)
    }

    /// Streams from an attached RSP. Skipped when the API or a device is missing.
    func testStreamsFromAttachedDevice() throws {
        guard SDRplaySource.isLibraryAvailable, let dev = SDRplaySource.listDevices().first else {
            throw XCTSkip("no SDRplay device attached")
        }
        let src = SDRplaySource(serial: dev.serial, config: SDRplayConfig())
        let lock = NSLock()
        var samples = 0
        var peak: Int16 = 0
        try src.start(sampleRate: 2_000_000, centerFrequency: 99_400_000) { block in
            guard case .s16(let b) = block else { return }
            let m = b.map { $0 == .min ? .max : abs($0) }.max() ?? 0
            lock.withLock {
                samples += block.count
                peak = max(peak, m)
            }
        }
        Thread.sleep(forTimeInterval: 0.5)
        lock.withLock { samples = 0 }
        Thread.sleep(forTimeInterval: 2)
        let (count, p) = lock.withLock { (samples, peak) }
        let gainBefore = src.systemGainDB

        // Live changes: retune, then fixed gain with the LNA at its lowest setting.
        src.setCenterFrequency(101_600_000)
        var c = SDRplayConfig()
        c.ifAGC = false
        c.ifGainReduction = 59
        c.lnaState = src.lnaStateCount - 1
        XCTAssertFalse(src.configure(c), "gain changes must not need a restart")
        Thread.sleep(forTimeInterval: 1)
        let gainAfter = src.systemGainDB
        lock.withLock { samples = 0 }
        Thread.sleep(forTimeInterval: 1)
        let stillStreaming = lock.withLock { samples }
        var zeroIF = c
        zeroIF.ifMode = .zeroIF
        XCTAssertTrue(src.configure(zeroIF), "an IF mode change needs a restart")
        src.stop()

        print("SDRplay \(dev.label): \(Double(count) / 2) S/s, peak \(p), gain \(gainBefore ?? 0) → \(gainAfter ?? 0) dB")
        XCTAssertEqual(Double(count) / 2, 2_000_000, accuracy: 100_000)
        XCTAssertGreaterThan(p, 0)
        XCTAssertGreaterThan(stillStreaming, 1_500_000)
        if let gainBefore, let gainAfter { XCTAssertLessThan(gainAfter, gainBefore - 10) }
    }
}
