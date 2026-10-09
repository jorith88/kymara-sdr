import Foundation

/// Plays back an I/Q recording (WAV with 8/16-bit PCM or 32-bit float, or raw .cu8), looping at real-time speed.
public final class FileSource: IQSource, @unchecked Sendable {
    enum SampleFormat {
        case u8, s16, f32
        var bytesPerSample: Int {
            switch self {
            case .u8: return 1
            case .s16: return 2
            case .f32: return 4
            }
        }
    }

    public let url: URL
    public var displayName: String { "File · \(url.lastPathComponent)" }
    public var gains: [Int] { [] }
    public let fixedSampleRate: Double?
    public let fixedCenterFrequency: Double?
    /// 8-bit files are passed through; 16-bit and float files are delivered as 16-bit to keep their resolution.
    public var sampleBits: Int { format == .u8 ? 8 : 16 }
    public var onError: ((String) -> Void)?
    public var onInfoChanged: (() -> Void)?

    private let format: SampleFormat
    private let dataOffset: UInt64
    private let dataLength: UInt64
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)

    public init(url: URL) throws {
        self.url = url
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SourceError.fileError("cannot open \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        let name = url.lastPathComponent

        if head.count >= 12, head.prefix(4) == Data("RIFF".utf8), head[8..<12] == Data("WAVE".utf8) {
            let info = try FileSource.parseWAV(handle: handle, fileSize: fileSize)
            format = info.format
            dataOffset = info.offset
            dataLength = info.length
            fixedSampleRate = info.rate
        } else {
            format = .u8
            dataOffset = 0
            dataLength = fileSize
            fixedSampleRate = FileSource.number(in: name, pattern: "([0-9]+)\\s*sps") ?? 2_048_000
        }
        fixedCenterFrequency = FileSource.number(in: name, pattern: "([0-9]{4,})\\s*Hz")
            ?? FileSource.number(in: name, pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*MHz").map { $0 * 1e6 }
            ?? 100_000_000
        guard dataLength >= 1024 else { throw SourceError.fileError("file contains no samples") }
    }

    static func number(in text: String, pattern: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }

    private static func parseWAV(handle: FileHandle, fileSize: UInt64) throws -> (format: SampleFormat, rate: Double, offset: UInt64, length: UInt64) {
        try handle.seek(toOffset: 12)
        var fmt: SampleFormat?
        var rate: Double = 0
        while true {
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            let size = UInt64(header[4]) | UInt64(header[5]) << 8 | UInt64(header[6]) << 16 | UInt64(header[7]) << 24
            let chunkStart = try handle.offset()
            if id == "fmt " {
                guard let body = try handle.read(upToCount: Int(min(size, 64))), body.count >= 16 else { break }
                let audioFormat = UInt16(body[0]) | UInt16(body[1]) << 8
                let channels = UInt16(body[2]) | UInt16(body[3]) << 8
                rate = Double(UInt32(body[4]) | UInt32(body[5]) << 8 | UInt32(body[6]) << 16 | UInt32(body[7]) << 24)
                let bits = UInt16(body[14]) | UInt16(body[15]) << 8
                guard channels == 2 else { throw SourceError.fileError("an I/Q WAV file must have 2 channels") }
                switch (audioFormat, bits) {
                case (1, 8): fmt = .u8
                case (1, 16): fmt = .s16
                case (3, 32): fmt = .f32
                case (0xFFFE, 16): fmt = .s16
                case (0xFFFE, 8): fmt = .u8
                case (0xFFFE, 32): fmt = .f32
                default: throw SourceError.fileError("unsupported WAV format (\(audioFormat), \(bits) bit)")
                }
            } else if id == "data" {
                guard let fmt, rate > 0 else { throw SourceError.fileError("WAV data before fmt chunk") }
                let length = min(size == 0 || size == 0xFFFF_FFFF ? fileSize - chunkStart : size, fileSize - chunkStart)
                return (fmt, rate, chunkStart, length)
            }
            try handle.seek(toOffset: chunkStart + size + (size & 1))
        }
        throw SourceError.fileError("no data chunk found")
    }

    deinit { stop() }

    public func start(sampleRate: Double, centerFrequency: Double, handler: @escaping IQHandler) throws {
        stop()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SourceError.fileError("cannot open \(url.lastPathComponent)")
        }
        lock.lock()
        running = true
        lock.unlock()
        let rate = fixedSampleRate ?? sampleRate
        let format = self.format
        let dataOffset = self.dataOffset
        let dataLength = self.dataLength
        let thread = Thread { [weak self] in
            defer { try? handle.close() }
            var pacer = RealTimePacer(rate: rate)
            let block = max(1024, Int(rate / 50))
            let frameBytes = 2 * format.bytesPerSample
            var position: UInt64 = 0
            var out8 = [UInt8](repeating: 127, count: format == .u8 ? block * 2 : 0)
            var out16 = [Int16](repeating: 0, count: format == .u8 ? 0 : block * 2)
            try? handle.seek(toOffset: dataOffset)
            while let self, self.isRunning {
                let want = UInt64(block * frameBytes)
                let remaining = dataLength - position
                let take = min(want, remaining - remaining % UInt64(frameBytes))
                guard take > 0, let data = try? handle.read(upToCount: Int(take)), !data.isEmpty else {
                    position = 0
                    try? handle.seek(toOffset: dataOffset)
                    continue
                }
                position += UInt64(data.count)
                let frames = data.count / frameBytes
                let count = frames * 2
                if format == .u8 {
                    data.copyBytes(to: &out8, count: count)
                    out8.withUnsafeBufferPointer { handler(.u8(UnsafeBufferPointer(rebasing: $0[0..<count]))) }
                } else {
                    FileSource.convert(data, format: format, count: count, into: &out16)
                    out16.withUnsafeBufferPointer { handler(.s16(UnsafeBufferPointer(rebasing: $0[0..<count]))) }
                }
                pacer.wait(afterProducing: frames)
            }
            self?.finished.signal()
        }
        thread.name = "IQ file reader"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private static func convert(_ data: Data, format: SampleFormat, count: Int, into out: inout [Int16]) {
        data.withUnsafeBytes { raw in
            switch format {
            case .u8:
                for i in 0..<count { out[i] = Int16(Int(raw[i]) - 128) << 8 }
            case .s16:
                let p = raw.bindMemory(to: Int16.self)
                for i in 0..<count { out[i] = Int16(littleEndian: p[i]) }
            case .f32:
                let p = raw.bindMemory(to: Float.self)
                for i in 0..<count { out[i] = Int16(max(-32768, min(32767, (p[i] * 32768).rounded()))) }
            }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning, thread != nil {
            _ = finished.wait(timeout: .now() + 2)
        }
        thread = nil
    }

    public func setCenterFrequency(_ hz: Double) {}
}
