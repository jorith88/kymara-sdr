import Foundation

/// A block of interleaved I/Q samples: unsigned 8-bit (RTL-SDR native format) or signed 16-bit (SDRplay, WAV files).
public enum IQSamples {
    case u8(UnsafeBufferPointer<UInt8>)
    case s16(UnsafeBufferPointer<Int16>)

    /// Number of complex samples.
    public var count: Int {
        switch self {
        case .u8(let b): return b.count / 2
        case .s16(let b): return b.count / 2
        }
    }

    /// Bits per I or Q value.
    public var bits: Int {
        switch self {
        case .u8: return 8
        case .s16: return 16
        }
    }
}

/// Receives I/Q sample blocks from a source.
public typealias IQHandler = (IQSamples) -> Void

public enum SourceError: LocalizedError {
    case libraryMissing
    case noDevice
    case openFailed(Int32)
    case fileError(String)
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .libraryMissing:
            return "librtlsdr was not found. Install it with 'brew install librtlsdr' or use the bundled app."
        case .noDevice:
            return "No RTL-SDR device found. Check the USB connection."
        case .openFailed(let code):
            return "Could not open the RTL-SDR device (error \(code)). Is another program using it?"
        case .fileError(let msg):
            return "IQ file error: \(msg)"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        }
    }
}

/// A source of raw I/Q samples. Setters may be called before or after `start`.
public protocol IQSource: AnyObject {
    var displayName: String { get }
    /// Available tuner gains in tenths of a dB.
    var gains: [Int] { get }
    /// Set for sources that dictate their own rate (files).
    var fixedSampleRate: Double? { get }
    /// Set for sources that cannot be retuned (files).
    var fixedCenterFrequency: Double? { get }
    /// Bits per I or Q value the source delivers (8 or 16); I/Q recordings use the same width.
    var sampleBits: Int { get }
    /// Sample rates the source supports; nil means the RTL-SDR set.
    var sampleRates: [Double]? { get }
    /// Called (on any thread) when the source fails after starting.
    var onError: ((String) -> Void)? { get set }
    /// Called (on any thread) when `gains` or other info changed.
    var onInfoChanged: (() -> Void)? { get set }

    func start(sampleRate: Double, centerFrequency: Double, handler: @escaping IQHandler) throws
    func stop()
    func setCenterFrequency(_ hz: Double)
    /// nil selects automatic tuner gain.
    func setGain(_ tenthsDB: Int?)
    func setPPM(_ ppm: Int)
    func setRTLAGC(_ on: Bool)
    /// 0 = off, 1 = I branch, 2 = Q branch.
    func setDirectSampling(_ mode: Int)
    func setBiasTee(_ on: Bool)
    func setOffsetTuning(_ on: Bool)
}

public extension IQSource {
    var fixedSampleRate: Double? { nil }
    var fixedCenterFrequency: Double? { nil }
    var sampleBits: Int { 8 }
    var sampleRates: [Double]? { nil }
    func setGain(_ tenthsDB: Int?) {}
    func setPPM(_ ppm: Int) {}
    func setRTLAGC(_ on: Bool) {}
    func setDirectSampling(_ mode: Int) {}
    func setBiasTee(_ on: Bool) {}
    func setOffsetTuning(_ on: Bool) {}
}

public enum TunerGains {
    public static let r820t = [0, 9, 14, 27, 37, 77, 87, 125, 144, 157, 166, 197, 207, 229, 254,
                               280, 297, 328, 338, 364, 372, 386, 402, 421, 434, 439, 445, 480, 496]
    public static let e4000 = [-10, 15, 40, 65, 90, 115, 140, 165, 190, 215, 240, 290, 340, 420]
    public static let fc0012 = [-99, -40, 71, 179, 192]

    public static func forTunerType(_ type: Int) -> [Int] {
        switch type {
        case 1: return e4000
        case 2: return fc0012
        default: return r820t
        }
    }

    public static func tunerName(_ type: Int) -> String {
        switch type {
        case 1: return "E4000"
        case 2: return "FC0012"
        case 3: return "FC0013"
        case 4: return "FC2580"
        case 5: return "R820T/R860"
        case 6: return "R828D"
        default: return "Unknown"
        }
    }
}

/// Paces a producer loop to real time.
struct RealTimePacer {
    private let start = DispatchTime.now().uptimeNanoseconds
    private var produced: Double = 0
    let rate: Double

    init(rate: Double) { self.rate = rate }

    mutating func wait(afterProducing samples: Int) {
        produced += Double(samples)
        let due = start + UInt64(produced / rate * 1e9)
        let now = DispatchTime.now().uptimeNanoseconds
        if due > now {
            Thread.sleep(forTimeInterval: Double(due - now) / 1e9)
        }
    }
}
