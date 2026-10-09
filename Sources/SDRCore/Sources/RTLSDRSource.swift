import Foundation
import Darwin

/// librtlsdr loaded at runtime, so the app builds and runs without it and can use a bundled copy.
final class RTLSDRLibrary: @unchecked Sendable {
    typealias ReadCallback = @convention(c) (UnsafeMutablePointer<UInt8>?, UInt32, UnsafeMutableRawPointer?) -> Void
    typealias FnCount = @convention(c) () -> UInt32
    typealias FnName = @convention(c) (UInt32) -> UnsafePointer<CChar>?
    typealias FnUSBStrings = @convention(c) (UInt32, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?) -> Int32
    typealias FnOpen = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, UInt32) -> Int32
    typealias FnDev = @convention(c) (OpaquePointer?) -> Int32
    typealias FnDevU32 = @convention(c) (OpaquePointer?, UInt32) -> Int32
    typealias FnDevI32 = @convention(c) (OpaquePointer?, Int32) -> Int32
    typealias FnGains = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>?) -> Int32
    typealias FnReadAsync = @convention(c) (OpaquePointer?, ReadCallback?, UnsafeMutableRawPointer?, UInt32, UInt32) -> Int32

    static let shared: RTLSDRLibrary? = RTLSDRLibrary()

    static var searchPaths: [String] {
        var paths: [String] = []
        if let fw = Bundle.main.privateFrameworksPath {
            paths.append(fw + "/librtlsdr.0.dylib")
        }
        paths += [
            "/opt/homebrew/lib/librtlsdr.0.dylib",
            "/opt/homebrew/lib/librtlsdr.dylib",
            "/usr/local/lib/librtlsdr.0.dylib",
            "/usr/local/lib/librtlsdr.dylib",
            "/opt/local/lib/librtlsdr.dylib",
        ]
        return paths
    }

    let loadedPath: String
    let getDeviceCount: FnCount
    let getDeviceName: FnName
    let getDeviceUSBStrings: FnUSBStrings
    let open: FnOpen
    let close: FnDev
    let setCenterFreq: FnDevU32
    let setFreqCorrection: FnDevI32
    let getTunerType: FnDev
    let getTunerGains: FnGains
    let setTunerGain: FnDevI32
    let setTunerGainMode: FnDevI32
    let setTunerBandwidth: FnDevU32?
    let setSampleRate: FnDevU32
    let setAGCMode: FnDevI32
    let setDirectSampling: FnDevI32
    let setOffsetTuning: FnDevI32
    let resetBuffer: FnDev
    let readAsync: FnReadAsync
    let cancelAsync: FnDev
    let setBiasTee: FnDevI32?

    private init?() {
        var handle: UnsafeMutableRawPointer?
        var path = ""
        for p in Self.searchPaths where FileManager.default.fileExists(atPath: p) {
            if let h = dlopen(p, RTLD_NOW | RTLD_LOCAL) {
                handle = h
                path = p
                break
            }
        }
        guard let handle else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let getDeviceCount = sym("rtlsdr_get_device_count", FnCount.self),
              let getDeviceName = sym("rtlsdr_get_device_name", FnName.self),
              let getDeviceUSBStrings = sym("rtlsdr_get_device_usb_strings", FnUSBStrings.self),
              let open = sym("rtlsdr_open", FnOpen.self),
              let close = sym("rtlsdr_close", FnDev.self),
              let setCenterFreq = sym("rtlsdr_set_center_freq", FnDevU32.self),
              let setFreqCorrection = sym("rtlsdr_set_freq_correction", FnDevI32.self),
              let getTunerType = sym("rtlsdr_get_tuner_type", FnDev.self),
              let getTunerGains = sym("rtlsdr_get_tuner_gains", FnGains.self),
              let setTunerGain = sym("rtlsdr_set_tuner_gain", FnDevI32.self),
              let setTunerGainMode = sym("rtlsdr_set_tuner_gain_mode", FnDevI32.self),
              let setSampleRate = sym("rtlsdr_set_sample_rate", FnDevU32.self),
              let setAGCMode = sym("rtlsdr_set_agc_mode", FnDevI32.self),
              let setDirectSampling = sym("rtlsdr_set_direct_sampling", FnDevI32.self),
              let setOffsetTuning = sym("rtlsdr_set_offset_tuning", FnDevI32.self),
              let resetBuffer = sym("rtlsdr_reset_buffer", FnDev.self),
              let readAsync = sym("rtlsdr_read_async", FnReadAsync.self),
              let cancelAsync = sym("rtlsdr_cancel_async", FnDev.self)
        else {
            dlclose(handle)
            return nil
        }
        self.loadedPath = path
        self.getDeviceCount = getDeviceCount
        self.getDeviceName = getDeviceName
        self.getDeviceUSBStrings = getDeviceUSBStrings
        self.open = open
        self.close = close
        self.setCenterFreq = setCenterFreq
        self.setFreqCorrection = setFreqCorrection
        self.getTunerType = getTunerType
        self.getTunerGains = getTunerGains
        self.setTunerGain = setTunerGain
        self.setTunerGainMode = setTunerGainMode
        self.setTunerBandwidth = sym("rtlsdr_set_tuner_bandwidth", FnDevU32.self)
        self.setSampleRate = setSampleRate
        self.setAGCMode = setAGCMode
        self.setDirectSampling = setDirectSampling
        self.setOffsetTuning = setOffsetTuning
        self.resetBuffer = resetBuffer
        self.readAsync = readAsync
        self.cancelAsync = cancelAsync
        self.setBiasTee = sym("rtlsdr_set_bias_tee", FnDevI32.self)
    }
}

public struct RTLDeviceInfo: Identifiable, Hashable, Sendable {
    public let index: UInt32
    public let name: String
    public let manufacturer: String
    public let product: String
    public let serial: String
    public var id: UInt32 { index }

    public var label: String {
        let base = product.isEmpty ? name : "\(manufacturer) \(product)".trimmingCharacters(in: .whitespaces)
        return serial.isEmpty ? base : "\(base) (SN \(serial))"
    }
}

private let rtlReadCallback: RTLSDRLibrary.ReadCallback = { buf, len, ctx in
    guard let buf, let ctx else { return }
    let source = Unmanaged<RTLSDRSource>.fromOpaque(ctx).takeUnretainedValue()
    source.deliver(UnsafeBufferPointer(start: buf, count: Int(len)))
}

public final class RTLSDRSource: IQSource, @unchecked Sendable {
    public static var isLibraryAvailable: Bool { RTLSDRLibrary.shared != nil }
    public static var libraryPath: String? { RTLSDRLibrary.shared?.loadedPath }

    public static func listDevices() -> [RTLDeviceInfo] {
        guard let lib = RTLSDRLibrary.shared else { return [] }
        let count = lib.getDeviceCount()
        return (0..<count).map { index in
            let name = lib.getDeviceName(index).map { String(cString: $0) } ?? "RTL-SDR"
            var m = [CChar](repeating: 0, count: 256)
            var p = [CChar](repeating: 0, count: 256)
            var s = [CChar](repeating: 0, count: 256)
            _ = lib.getDeviceUSBStrings(index, &m, &p, &s)
            return RTLDeviceInfo(index: index, name: name,
                                 manufacturer: String(cString: m), product: String(cString: p), serial: String(cString: s))
        }
    }

    public let deviceIndex: UInt32
    public private(set) var displayName: String
    public private(set) var gains: [Int] = TunerGains.r820t
    public private(set) var tunerName = ""
    public var onError: ((String) -> Void)?
    public var onInfoChanged: (() -> Void)?

    private let lock = NSLock()
    private var dev: OpaquePointer?
    private var handler: IQHandler?
    private var readThreadDone = DispatchSemaphore(value: 0)
    private var stopping = false

    // Settings remembered so they can be applied when the device opens.
    private var gain: Int? = nil
    private var ppm = 0
    private var rtlAGC = false
    private var directSampling = 0
    private var biasTee = false
    private var offsetTuning = false

    public init(deviceIndex: UInt32, name: String = "RTL-SDR") {
        self.deviceIndex = deviceIndex
        self.displayName = name
    }

    deinit { stop() }

    fileprivate func deliver(_ buffer: UnsafeBufferPointer<UInt8>) {
        handler?(.u8(buffer))
    }

    public func start(sampleRate: Double, centerFrequency: Double, handler: @escaping IQHandler) throws {
        guard let lib = RTLSDRLibrary.shared else { throw SourceError.libraryMissing }
        guard lib.getDeviceCount() > deviceIndex else { throw SourceError.noDevice }
        var d: OpaquePointer?
        let r = lib.open(&d, deviceIndex)
        guard r == 0, let d else { throw SourceError.openFailed(r) }

        lock.lock()
        dev = d
        stopping = false
        lock.unlock()

        let type = Int(lib.getTunerType(d))
        tunerName = TunerGains.tunerName(type)
        let n = lib.getTunerGains(d, nil)
        if n > 0 {
            var g = [Int32](repeating: 0, count: Int(n))
            _ = lib.getTunerGains(d, &g)
            gains = g.map(Int.init)
        } else {
            gains = TunerGains.forTunerType(type)
        }
        displayName = "RTL-SDR #\(deviceIndex) · \(tunerName)"

        _ = lib.setSampleRate(d, UInt32(sampleRate))
        _ = lib.setTunerBandwidth?(d, 0)
        _ = lib.setDirectSampling(d, Int32(directSampling))
        _ = lib.setOffsetTuning(d, offsetTuning ? 1 : 0)
        _ = lib.setCenterFreq(d, UInt32(clamping: Int64(centerFrequency)))
        if ppm != 0 { _ = lib.setFreqCorrection(d, Int32(ppm)) }
        _ = lib.setAGCMode(d, rtlAGC ? 1 : 0)
        applyGain(lib, d)
        _ = lib.setBiasTee?(d, biasTee ? 1 : 0)
        _ = lib.resetBuffer(d)

        self.handler = handler
        readThreadDone = DispatchSemaphore(value: 0)
        let done = readThreadDone
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let thread = Thread { [weak self] in
            // ~27 ms per buffer at 2.4 MS/s.
            let result = lib.readAsync(d, rtlReadCallback, ctx, 12, 16384 * 8)
            if let self {
                self.lock.lock()
                let wasStopping = self.stopping
                self.lock.unlock()
                if !wasStopping {
                    self.onError?("RTL-SDR stopped streaming (code \(result)). The device may have been disconnected.")
                }
            }
            done.signal()
        }
        thread.name = "RTL-SDR reader"
        thread.qualityOfService = .userInteractive
        thread.start()
        onInfoChanged?()
    }

    public func stop() {
        guard let lib = RTLSDRLibrary.shared else { return }
        lock.lock()
        guard let d = dev else { lock.unlock(); return }
        stopping = true
        lock.unlock()
        _ = lib.cancelAsync(d)
        _ = readThreadDone.wait(timeout: .now() + 3)
        lock.lock()
        dev = nil
        lock.unlock()
        _ = lib.close(d)
        handler = nil
    }

    private func withDevice(_ body: (RTLSDRLibrary, OpaquePointer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let lib = RTLSDRLibrary.shared, let d = dev, !stopping else { return }
        body(lib, d)
    }

    private func applyGain(_ lib: RTLSDRLibrary, _ d: OpaquePointer) {
        if let gain {
            _ = lib.setTunerGainMode(d, 1)
            _ = lib.setTunerGain(d, Int32(gain))
        } else {
            _ = lib.setTunerGainMode(d, 0)
        }
    }

    public func setCenterFrequency(_ hz: Double) {
        withDevice { lib, d in _ = lib.setCenterFreq(d, UInt32(clamping: Int64(hz))) }
    }

    public func setGain(_ tenthsDB: Int?) {
        gain = tenthsDB
        withDevice { lib, d in applyGain(lib, d) }
    }

    public func setPPM(_ ppm: Int) {
        self.ppm = ppm
        withDevice { lib, d in _ = lib.setFreqCorrection(d, Int32(ppm)) }
    }

    public func setRTLAGC(_ on: Bool) {
        rtlAGC = on
        withDevice { lib, d in _ = lib.setAGCMode(d, on ? 1 : 0) }
    }

    public func setDirectSampling(_ mode: Int) {
        directSampling = mode
        withDevice { lib, d in _ = lib.setDirectSampling(d, Int32(mode)) }
    }

    public func setBiasTee(_ on: Bool) {
        biasTee = on
        withDevice { lib, d in _ = lib.setBiasTee?(d, on ? 1 : 0) }
    }

    public func setOffsetTuning(_ on: Bool) {
        offsetTuning = on
        withDevice { lib, d in _ = lib.setOffsetTuning(d, on ? 1 : 0) }
    }
}
