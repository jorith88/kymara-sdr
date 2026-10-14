import XCTest
import AVFoundation
@testable import SDRCore

final class SourceTests: XCTestCase {
    func testDemoSourceKeepsRealTime() throws {
        let src = DemoSource()
        let lock = NSLock()
        var bytes = 0
        try src.start(sampleRate: 2_400_000, centerFrequency: 100_000_000) { buf in
            lock.withLock { bytes += 2 * buf.count }
        }
        Thread.sleep(forTimeInterval: 2)
        src.stop()
        let rate = Double(lock.withLock { bytes }) / 2 / 2
        print("demo rate \(rate)")
        XCTAssertEqual(rate, 2_400_000, accuracy: 120_000)
    }

    func testFileNameParsing() {
        XCTAssertEqual(FileSource.number(in: "IQ_20261007_100000000Hz_2400000sps.wav", pattern: "([0-9]{4,})\\s*Hz"), 100_000_000)
        XCTAssertEqual(FileSource.number(in: "IQ_20261007_100000000Hz_2400000sps.wav", pattern: "([0-9]+)\\s*sps"), 2_400_000)
    }
}

final class RecorderTests: XCTestCase {
    func testIQRecordingPlaysBackAsFileSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("IQ_test_145500000Hz_1024000sps.wav")

        let rec = Recorder()
        try rec.startIQ(url: url, sampleRate: 1_024_000)
        let payload = (0..<200_000).map { UInt8(truncatingIfNeeded: $0) }
        payload.withUnsafeBufferPointer { rec.writeIQ(.u8($0)) }
        rec.stopIQ()

        let src = try FileSource(url: url)
        XCTAssertEqual(src.fixedSampleRate, 1_024_000)
        XCTAssertEqual(src.fixedCenterFrequency, 145_500_000)

        let lock = NSLock()
        var received: [UInt8] = []
        XCTAssertEqual(src.sampleBits, 8)
        try src.start(sampleRate: 0, centerFrequency: 0) { samples in
            guard case .u8(let buf) = samples else { return XCTFail("expected 8-bit samples") }
            lock.withLock { if received.count < payload.count { received += buf } }
        }
        Thread.sleep(forTimeInterval: 0.4)
        src.stop()
        let got = lock.withLock { received }
        XCTAssertGreaterThanOrEqual(got.count, payload.count)
        XCTAssertEqual(Array(got.prefix(payload.count)), payload)
    }

    /// A failing write (full disk, removed volume) stops the recording and reports it once.
    func testIQWriteErrorStopsRecording() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recorder()
        var messages: [String] = []
        rec.onAutoStop = { messages.append($0) }
        try rec.startIQ(url: dir.appendingPathComponent("iq.wav"), sampleRate: 1_024_000)
        let block = [UInt8](repeating: 127, count: 4096)
        block.withUnsafeBufferPointer { rec.writeIQ(.u8($0)) }
        rec.closeIQFileForTesting()
        for _ in 0..<3 { block.withUnsafeBufferPointer { rec.writeIQ(.u8($0)) } }
        XCTAssertFalse(rec.isRecordingIQ)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages.first?.hasPrefix("I/Q recording stopped: ") ?? false, messages.first ?? "")
    }

    func testAudioWriteErrorStopsRecording() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recorder()
        var messages: [String] = []
        rec.onAutoStop = { messages.append($0) }
        let samples = [Float](repeating: 0.1, count: 4800)
        // A finished recording, opened for reading: writing to it fails.
        let first = dir.appendingPathComponent("first.wav")
        try rec.startAudio(url: first, sampleRate: 48_000)
        rec.writeAudio(left: samples, right: samples, count: samples.count)
        rec.stopAudio()
        XCTAssertEqual(messages, [])

        try rec.startAudio(url: dir.appendingPathComponent("second.wav"), sampleRate: 48_000)
        rec.replaceAudioFileForTesting(try AVAudioFile(forReading: first, commonFormat: .pcmFormatFloat32, interleaved: false))
        for _ in 0..<3 { rec.writeAudio(left: samples, right: samples, count: samples.count) }
        XCTAssertFalse(rec.isRecordingAudio)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages.first?.hasPrefix("Audio recording stopped: ") ?? false, messages.first ?? "")
    }

    func test16BitIQRecordingPlaysBackAt16Bit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("IQ_test_99400000Hz_2000000sps.wav")

        let rec = Recorder()
        try rec.startIQ(url: url, sampleRate: 2_000_000, bitsPerSample: 16)
        let payload = (0..<200_000).map { Int16(truncatingIfNeeded: $0 &* 37) }
        payload.withUnsafeBufferPointer { rec.writeIQ(.s16($0)) }
        // Blocks of the wrong width are skipped rather than corrupting the file.
        [UInt8](repeating: 1, count: 64).withUnsafeBufferPointer { rec.writeIQ(.u8($0)) }
        rec.stopIQ()

        let src = try FileSource(url: url)
        XCTAssertEqual(src.fixedSampleRate, 2_000_000)
        XCTAssertEqual(src.sampleBits, 16)

        let lock = NSLock()
        var received: [Int16] = []
        try src.start(sampleRate: 0, centerFrequency: 0) { samples in
            guard case .s16(let buf) = samples else { return XCTFail("expected 16-bit samples") }
            lock.withLock { if received.count < payload.count { received += buf } }
        }
        Thread.sleep(forTimeInterval: 0.4)
        src.stop()
        let got = lock.withLock { received }
        XCTAssertGreaterThanOrEqual(got.count, payload.count)
        XCTAssertEqual(Array(got.prefix(payload.count)), payload)
    }
}
