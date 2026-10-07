import Foundation
import AVFoundation

/// Writes demodulated audio (16-bit stereo WAV) and raw I/Q (8-bit unsigned stereo WAV, the RTL-SDR native format).
public final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var iqHandle: FileHandle?
    private var iqBytes: UInt64 = 0
    private var iqSampleRate: UInt32 = 0
    private var audioFile: AVAudioFile?
    private var audioBuffer: AVAudioPCMBuffer?
    public private(set) var iqURL: URL?
    public private(set) var audioURL: URL?

    /// Called when a recording stops by itself (e.g. size limit).
    public var onAutoStop: ((String) -> Void)?

    public init() {}

    public var isRecordingIQ: Bool { lock.withLock { iqHandle != nil } }
    public var isRecordingAudio: Bool { lock.withLock { audioFile != nil } }

    // MARK: I/Q

    public func startIQ(url: URL, sampleRate: Double) throws {
        stopIQ()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Recorder.wavHeader(sampleRate: UInt32(sampleRate), dataBytes: 0))
        lock.withLock {
            iqHandle = handle
            iqBytes = 0
            iqSampleRate = UInt32(sampleRate)
            iqURL = url
        }
    }

    func writeIQ(_ bytes: UnsafeBufferPointer<UInt8>) {
        var limitHit = false
        lock.withLock {
            guard let handle = iqHandle else { return }
            if iqBytes + UInt64(bytes.count) > 0xFFFF_0000 {
                limitHit = true
                return
            }
            try? handle.write(contentsOf: Data(buffer: bytes))
            iqBytes += UInt64(bytes.count)
        }
        if limitHit {
            stopIQ()
            onAutoStop?("I/Q recording stopped at the 4 GB WAV limit.")
        }
    }

    public func stopIQ() {
        lock.withLock {
            guard let handle = iqHandle else { return }
            try? handle.seek(toOffset: 0)
            try? handle.write(contentsOf: Recorder.wavHeader(sampleRate: iqSampleRate, dataBytes: UInt32(iqBytes)))
            try? handle.close()
            iqHandle = nil
        }
    }

    static func wavHeader(sampleRate: UInt32, dataBytes: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                 // PCM
        u16(2)                 // I and Q
        u32(sampleRate)
        u32(sampleRate * 2)    // byte rate
        u16(2)                 // block align
        u16(8)                 // bits, unsigned
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    // MARK: Audio

    public func startAudio(url: URL, sampleRate: Double) throws {
        stopAudio()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.withLock {
            audioFile = file
            audioBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 15)
            audioURL = url
        }
    }

    func writeAudio(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        lock.withLock {
            guard let file = audioFile, let buffer = audioBuffer, count > 0 else { return }
            var done = 0
            while done < count {
                let chunk = min(count - done, Int(buffer.frameCapacity))
                guard let ch = buffer.floatChannelData else { return }
                ch[0].update(from: left + done, count: chunk)
                ch[1].update(from: right + done, count: chunk)
                buffer.frameLength = AVAudioFrameCount(chunk)
                try? file.write(from: buffer)
                done += chunk
            }
        }
    }

    public func stopAudio() {
        lock.withLock {
            audioFile = nil
            audioBuffer = nil
        }
    }
}
