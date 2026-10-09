import Foundation
import Darwin
import CSDRplay

/// The SDRplay API 3.x (libsdrplay_api), loaded at runtime. It is closed source and installed system-wide by the
/// user together with its background service, so it is never bundled.
final class SDRplayLibrary: @unchecked Sendable {
    typealias FnVoid = @convention(c) () -> Int32
    typealias FnApiVersion = @convention(c) (UnsafeMutablePointer<Float>?) -> Int32
    typealias FnGetDevices = @convention(c) (UnsafeMutablePointer<ksdrplay_Device>?, UnsafeMutablePointer<UInt32>?, UInt32) -> Int32
    typealias FnDevice = @convention(c) (UnsafeMutablePointer<ksdrplay_Device>?) -> Int32
    typealias FnErrorString = @convention(c) (Int32) -> UnsafePointer<CChar>?
    typealias FnGetDeviceParams = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutablePointer<ksdrplay_DeviceParams>?>?) -> Int32
    typealias FnInit = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<ksdrplay_CallbackFns>?, UnsafeMutableRawPointer?) -> Int32
    typealias FnUninit = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias FnUpdate = @convention(c) (UnsafeMutableRawPointer?, Int32, UInt32, UInt32) -> Int32

    /// The struct layouts in sdrplay_shim.h were checked against this version (scripts/check-sdrplay-shim.sh).
    static let minimumVersion: Float = 3.15
    static let shared: SDRplayLibrary? = SDRplayLibrary()

    static let searchPaths = [
        "/usr/local/lib/libsdrplay_api.so.3",
        "/usr/local/lib/libsdrplay_api.so",
        "/usr/local/lib/libsdrplay_api.dylib",
        "/opt/homebrew/lib/libsdrplay_api.so.3",
    ]

    let loadedPath: String
    let open: FnVoid
    let apiVersion: FnApiVersion
    let lockDeviceApi: FnVoid
    let unlockDeviceApi: FnVoid
    let getDevices: FnGetDevices
    let selectDevice: FnDevice
    let releaseDevice: FnDevice
    let getErrorString: FnErrorString
    let getDeviceParams: FnGetDeviceParams
    let initDevice: FnInit
    let uninit: FnUninit
    let update: FnUpdate

    private let openLock = NSLock()
    private var isOpen = false

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
        guard let open = sym("sdrplay_api_Open", FnVoid.self),
              let apiVersion = sym("sdrplay_api_ApiVersion", FnApiVersion.self),
              let lockDeviceApi = sym("sdrplay_api_LockDeviceApi", FnVoid.self),
              let unlockDeviceApi = sym("sdrplay_api_UnlockDeviceApi", FnVoid.self),
              let getDevices = sym("sdrplay_api_GetDevices", FnGetDevices.self),
              let selectDevice = sym("sdrplay_api_SelectDevice", FnDevice.self),
              let releaseDevice = sym("sdrplay_api_ReleaseDevice", FnDevice.self),
              let getErrorString = sym("sdrplay_api_GetErrorString", FnErrorString.self),
              let getDeviceParams = sym("sdrplay_api_GetDeviceParams", FnGetDeviceParams.self),
              let initDevice = sym("sdrplay_api_Init", FnInit.self),
              let uninit = sym("sdrplay_api_Uninit", FnUninit.self),
              let update = sym("sdrplay_api_Update", FnUpdate.self)
        else {
            dlclose(handle)
            return nil
        }
        self.loadedPath = path
        self.open = open
        self.apiVersion = apiVersion
        self.lockDeviceApi = lockDeviceApi
        self.unlockDeviceApi = unlockDeviceApi
        self.getDevices = getDevices
        self.selectDevice = selectDevice
        self.releaseDevice = releaseDevice
        self.getErrorString = getErrorString
        self.getDeviceParams = getDeviceParams
        self.initDevice = initDevice
        self.uninit = uninit
        self.update = update
    }

    func errorText(_ code: Int32) -> String {
        getErrorString(code).map { String(cString: $0) } ?? "error \(code)"
    }

    /// Connects to the API service once per process; the connection stays open until the app quits.
    func ensureOpen() throws {
        openLock.lock()
        defer { openLock.unlock() }
        if isOpen { return }
        let r = open()
        guard r == 0 else {
            throw r == 14 ? SourceError.sdrplayService : SourceError.sdrplayError(errorText(r))
        }
        var version: Float = 0
        _ = apiVersion(&version)
        guard version >= Self.minimumVersion - 0.001, version < 4 else {
            throw SourceError.sdrplayError(String(format: "SDRplay API %.2f is not supported. Install version 3.15 or newer.", version))
        }
        isOpen = true
    }
}

/// `sdrplay_api_ReasonForUpdateT` and `sdrplay_api_ReasonForUpdateExtension1T` flags.
enum SDRplayUpdate {
    static let devPpm: UInt32 = 0x0000_0002
    static let rsp1aBiasT: UInt32 = 0x0000_0010
    static let rsp1aRfNotch: UInt32 = 0x0000_0020
    static let rsp1aDabNotch: UInt32 = 0x0000_0040
    static let rsp2BiasT: UInt32 = 0x0000_0080
    static let rsp2AmPort: UInt32 = 0x0000_0100
    static let rsp2Antenna: UInt32 = 0x0000_0200
    static let rsp2RfNotch: UInt32 = 0x0000_0400
    static let tunerGr: UInt32 = 0x0000_8000
    static let tunerFrf: UInt32 = 0x0002_0000
    static let ctrlAgc: UInt32 = 0x0100_0000
    static let ctrlOverloadAck: UInt32 = 0x0400_0000
    static let duoBiasT: UInt32 = 0x0800_0000
    static let duoAmPort: UInt32 = 0x1000_0000
    static let duoAmNotch: UInt32 = 0x2000_0000
    static let duoRfNotch: UInt32 = 0x4000_0000
    static let duoDabNotch: UInt32 = 0x8000_0000
    // Extension 1.
    static let dxBiasT: UInt32 = 0x02
    static let dxAntenna: UInt32 = 0x04
    static let dxRfNotch: UInt32 = 0x08
    static let dxDabNotch: UInt32 = 0x10
}

private let sdrplayStreamCallback: @convention(c) (UnsafeMutablePointer<Int16>?, UnsafeMutablePointer<Int16>?,
                                                   UnsafeMutablePointer<ksdrplay_StreamCbParams>?, UInt32, UInt32,
                                                   UnsafeMutableRawPointer?) -> Void = { xi, xq, _, count, reset, ctx in
    guard let xi, let xq, let ctx else { return }
    Unmanaged<SDRplaySource>.fromOpaque(ctx).takeUnretainedValue().stream(xi, xq, Int(count), reset: reset != 0)
}

private let sdrplayEventCallback: @convention(c) (Int32, Int32, UnsafeMutablePointer<ksdrplay_EventParams>?,
                                                  UnsafeMutableRawPointer?) -> Void = { event, _, params, ctx in
    guard let ctx else { return }
    Unmanaged<SDRplaySource>.fromOpaque(ctx).takeUnretainedValue().event(event, params)
}

/// SDRplay RSP receivers (RSP1, RSP1A, RSP1B, RSP2, RSPduo in single-tuner mode, RSPdx, RSPdx-R2) through the
/// SDRplay API. Delivers 16-bit samples.
public final class SDRplaySource: IQSource, @unchecked Sendable {
    public static var isLibraryAvailable: Bool { SDRplayLibrary.shared != nil }
    public static var libraryPath: String? { SDRplayLibrary.shared?.loadedPath }

    /// Devices that are attached and not in use by another program (or by a running source).
    public static func listDevices() -> [SDRplayDeviceInfo] {
        guard let lib = SDRplayLibrary.shared, (try? lib.ensureOpen()) != nil else { return [] }
        var devices = [ksdrplay_Device](repeating: ksdrplay_Device(), count: Int(KSDRPLAY_MAX_DEVICES))
        var count: UInt32 = 0
        _ = lib.lockDeviceApi()
        let r = lib.getDevices(&devices, &count, UInt32(KSDRPLAY_MAX_DEVICES))
        _ = lib.unlockDeviceApi()
        guard r == 0 else { return [] }
        return devices.prefix(Int(count)).map { d in
            SDRplayDeviceInfo(serial: Self.serial(of: d), hwVer: d.hwVer)
        }
    }

    private static func serial(of device: ksdrplay_Device) -> String {
        withUnsafeBytes(of: device.SerNo) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    public let serialNumber: String
    public private(set) var displayName: String
    public var gains: [Int] { [] }
    public var sampleBits: Int { 16 }
    public var sampleRates: [Double]? { SDRplayRatePlan.outputRates }
    public var onError: ((String) -> Void)?
    public var onInfoChanged: (() -> Void)?

    private let lock = NSLock()
    private var device = ksdrplay_Device()
    private var params: UnsafeMutablePointer<ksdrplay_DeviceParams>?
    private var running = false
    private var currentModel: SDRplayModel = .unknown(0)
    private var config: SDRplayConfig
    private var outputRate: Double = 2_000_000
    private var plan = SDRplayRatePlan.plan(outputRate: 2_000_000, ifMode: .auto)
    private var center: Double = 100_000_000
    private var ppm = 0
    private var biasTee = false
    private var lnaCount = 4
    private var overloaded = false
    private var gainDB: Double?

    // Stream state, only touched on the API's stream thread (and in start/stop while it is not running).
    private var handler: IQHandler?
    private var accumulator: [Int16] = []
    private var accumulated = 0
    private var chunk = 16_384

    public init(serial: String, config: SDRplayConfig) {
        self.serialNumber = serial
        self.config = config
        self.displayName = serial.isEmpty ? "SDRplay" : "SDRplay (SN \(serial))"
    }

    deinit { stop() }

    public var model: SDRplayModel { lock.withLock { currentModel } }
    /// Number of LNA states at the current frequency and antenna.
    public var lnaStateCount: Int { lock.withLock { lnaCount } }
    public var hardwareOverload: Bool { lock.withLock { overloaded } }
    /// Total receiver gain in dB as reported by the API (LNA and IF gain), for the S-meter.
    public var systemGainDB: Double? { lock.withLock { gainDB } }

    public func start(sampleRate: Double, centerFrequency: Double, handler: @escaping IQHandler) throws {
        stop()
        guard let lib = SDRplayLibrary.shared else { throw SourceError.sdrplayAPIMissing }
        try lib.ensureOpen()

        var devices = [ksdrplay_Device](repeating: ksdrplay_Device(), count: Int(KSDRPLAY_MAX_DEVICES))
        var count: UInt32 = 0
        _ = lib.lockDeviceApi()
        var r = lib.getDevices(&devices, &count, UInt32(KSDRPLAY_MAX_DEVICES))
        let found = devices.prefix(Int(count)).first { Self.serial(of: $0) == serialNumber }
            ?? (serialNumber.isEmpty ? devices.prefix(Int(count)).first : nil)
        guard r == 0, var d = found else {
            _ = lib.unlockDeviceApi()
            throw r == 0 ? SourceError.noSDRplayDevice : SourceError.sdrplayError(lib.errorText(r))
        }
        let model = SDRplayModel(hwVer: d.hwVer)
        if model == .rspDuo {
            d.tuner = config.antenna == .b ? 2 : 1
            d.rspDuoMode = 1   // single tuner
        }
        r = lib.selectDevice(&d)
        _ = lib.unlockDeviceApi()
        guard r == 0 else {
            throw SourceError.sdrplayError("Could not open the \(model.name) (\(lib.errorText(r))). Is another program using it?")
        }

        var p: UnsafeMutablePointer<ksdrplay_DeviceParams>?
        r = lib.getDeviceParams(d.dev, &p)
        guard r == 0, let p, p.pointee.devParams != nil, channel(p, tuner: d.tuner) != nil else {
            _ = lib.releaseDevice(&d)
            throw SourceError.sdrplayError("Could not read the device parameters (\(lib.errorText(r))).")
        }

        lock.lock()
        device = d
        params = p
        currentModel = model
        center = centerFrequency
        outputRate = sampleRate
        plan = SDRplayRatePlan.plan(outputRate: sampleRate, ifMode: config.ifMode)
        lnaCount = model.lnaStateCount(frequency: center, antenna: config.antenna)
        overloaded = false
        gainDB = nil
        writeAllParameters()
        displayName = "SDRplay \(model.name) · SN \(serialNumber.isEmpty ? Self.serial(of: d) : serialNumber)"
        lock.unlock()

        self.handler = handler
        chunk = max(4096, Int(sampleRate / 40))   // ~25 ms per block
        accumulator = [Int16](repeating: 0, count: 2 * chunk)
        accumulated = 0

        var callbacks = ksdrplay_CallbackFns(StreamACbFn: sdrplayStreamCallback, StreamBCbFn: sdrplayStreamCallback,
                                             EventCbFn: sdrplayEventCallback)
        r = lib.initDevice(d.dev, &callbacks, Unmanaged.passUnretained(self).toOpaque())
        guard r == 0 else {
            lock.withLock { params = nil }
            _ = lib.releaseDevice(&device)
            self.handler = nil
            throw SourceError.sdrplayError("Could not start streaming (\(lib.errorText(r))).")
        }
        lock.withLock { running = true }
        onInfoChanged?()
    }

    public func stop() {
        guard let lib = SDRplayLibrary.shared else { return }
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let dev = device.dev
        lock.unlock()
        _ = lib.uninit(dev)
        lock.lock()
        _ = lib.releaseDevice(&device)
        params = nil
        lock.unlock()
        handler = nil
    }

    // MARK: Settings

    /// Applies SDRplay settings. Returns true when a change needs a restart (IF mode, RSPduo tuner).
    @discardableResult
    public func configure(_ new: SDRplayConfig) -> Bool {
        lock.lock()
        let old = config
        config = new
        guard running else { lock.unlock(); return false }
        let newPlan = SDRplayRatePlan.plan(outputRate: outputRate, ifMode: new.ifMode)
        let duoTunerChanged = currentModel == .rspDuo && (old.antenna == .b) != (new.antenna == .b)
        if newPlan != plan || duoTunerChanged {
            lock.unlock()
            return true
        }
        var reasons: UInt32 = 0
        var ext: UInt32 = 0
        lnaCount = currentModel.lnaStateCount(frequency: center, antenna: new.antenna)
        writeAllParameters()
        if old.lnaState != new.lnaState || old.ifGainReduction != new.ifGainReduction || old.antenna != new.antenna {
            reasons |= SDRplayUpdate.tunerGr
        }
        if old.ifAGC != new.ifAGC { reasons |= SDRplayUpdate.ctrlAgc }
        switch currentModel {
        case .rsp1a, .rsp1b:
            if old.rfNotch != new.rfNotch { reasons |= SDRplayUpdate.rsp1aRfNotch }
            if old.dabNotch != new.dabNotch { reasons |= SDRplayUpdate.rsp1aDabNotch }
        case .rsp2:
            if old.antenna != new.antenna { reasons |= SDRplayUpdate.rsp2Antenna | SDRplayUpdate.rsp2AmPort }
            if old.rfNotch != new.rfNotch { reasons |= SDRplayUpdate.rsp2RfNotch }
        case .rspDuo:
            if old.antenna != new.antenna { reasons |= SDRplayUpdate.duoAmPort }
            if old.rfNotch != new.rfNotch { reasons |= SDRplayUpdate.duoRfNotch }
            if old.dabNotch != new.dabNotch { reasons |= SDRplayUpdate.duoDabNotch }
            if old.amNotch != new.amNotch { reasons |= SDRplayUpdate.duoAmNotch }
        case .rspDx, .rspDxR2:
            if old.antenna != new.antenna { ext |= SDRplayUpdate.dxAntenna }
            if old.rfNotch != new.rfNotch { ext |= SDRplayUpdate.dxRfNotch }
            if old.dabNotch != new.dabNotch { ext |= SDRplayUpdate.dxDabNotch }
        case .rsp1, .unknown:
            break
        }
        lock.unlock()
        sendUpdate(reasons, ext)
        onInfoChanged?()
        return false
    }

    public func setCenterFrequency(_ hz: Double) {
        lock.lock()
        center = min(max(hz, 1_000), 2_000_000_000)
        guard running else { lock.unlock(); return }
        let newCount = currentModel.lnaStateCount(frequency: center, antenna: config.antenna)
        let countChanged = newCount != lnaCount
        lnaCount = newCount
        writeAllParameters()
        lock.unlock()
        sendUpdate(SDRplayUpdate.tunerFrf | (countChanged ? SDRplayUpdate.tunerGr : 0), 0)
        if countChanged { onInfoChanged?() }
    }

    public func setPPM(_ ppm: Int) {
        lock.lock()
        self.ppm = ppm
        guard running else { lock.unlock(); return }
        writeAllParameters()
        lock.unlock()
        sendUpdate(SDRplayUpdate.devPpm, 0)
    }

    public func setBiasTee(_ on: Bool) {
        lock.lock()
        biasTee = on
        guard running else { lock.unlock(); return }
        writeAllParameters()
        let model = currentModel
        lock.unlock()
        switch model {
        case .rsp1a, .rsp1b: sendUpdate(SDRplayUpdate.rsp1aBiasT, 0)
        case .rsp2: sendUpdate(SDRplayUpdate.rsp2BiasT, 0)
        case .rspDuo: sendUpdate(SDRplayUpdate.duoBiasT, 0)
        case .rspDx, .rspDxR2: sendUpdate(0, SDRplayUpdate.dxBiasT)
        case .rsp1, .unknown: break
        }
    }

    // MARK: Internals

    private func channel(_ p: UnsafeMutablePointer<ksdrplay_DeviceParams>, tuner: Int32) -> UnsafeMutablePointer<ksdrplay_RxChannelParams>? {
        tuner == 2 ? p.pointee.rxChannelB : p.pointee.rxChannelA
    }

    /// Writes every setting into the API's parameter structs (lock held). `sendUpdate` makes them take effect.
    private func writeAllParameters() {
        guard let p = params, let dp = p.pointee.devParams, let rx = channel(p, tuner: device.tuner) else { return }
        let c = config
        dp.pointee.fsFreq.fsHz = plan.fsHz
        dp.pointee.ppm = Double(ppm)

        rx.pointee.tunerParams.bwType = plan.bwKHz
        rx.pointee.tunerParams.ifType = plan.ifKHz
        rx.pointee.tunerParams.rfFreq.rfHz = center
        rx.pointee.tunerParams.gain.minGr = 20
        rx.pointee.tunerParams.gain.gRdB = Int32(min(max(c.ifGainReduction, 20), 59))
        rx.pointee.tunerParams.gain.LNAstate = UInt8(min(max(c.lnaState, 0), lnaCount - 1))

        rx.pointee.ctrlParams.decimation.enable = plan.decimation > 1 ? 1 : 0
        rx.pointee.ctrlParams.decimation.decimationFactor = UInt8(plan.decimation)
        rx.pointee.ctrlParams.decimation.wideBandSignal = 1   // half-band filters instead of averaging
        rx.pointee.ctrlParams.dcOffset.DCenable = 1
        rx.pointee.ctrlParams.dcOffset.IQenable = 1
        rx.pointee.ctrlParams.agc.enable = c.ifAGC ? 2 : 0  // 50 Hz loop
        rx.pointee.ctrlParams.agc.setPoint_dBfs = -30

        switch currentModel {
        case .rsp1a, .rsp1b:
            dp.pointee.rsp1aParams.rfNotchEnable = c.rfNotch ? 1 : 0
            dp.pointee.rsp1aParams.rfDabNotchEnable = c.dabNotch ? 1 : 0
            rx.pointee.rsp1aTunerParams.biasTEnable = biasTee ? 1 : 0
        case .rsp2:
            rx.pointee.rsp2TunerParams.antennaSel = c.antenna == .b ? 6 : 5
            rx.pointee.rsp2TunerParams.amPortSel = c.antenna == .hiZ ? 1 : 0
            rx.pointee.rsp2TunerParams.rfNotchEnable = c.rfNotch ? 1 : 0
            rx.pointee.rsp2TunerParams.biasTEnable = biasTee ? 1 : 0
        case .rspDuo:
            rx.pointee.rspDuoTunerParams.tuner1AmPortSel = c.antenna == .hiZ ? 1 : 0
            rx.pointee.rspDuoTunerParams.rfNotchEnable = c.rfNotch ? 1 : 0
            rx.pointee.rspDuoTunerParams.rfDabNotchEnable = c.dabNotch ? 1 : 0
            rx.pointee.rspDuoTunerParams.tuner1AmNotchEnable = c.amNotch ? 1 : 0
            rx.pointee.rspDuoTunerParams.biasTEnable = biasTee ? 1 : 0   // tuner 2 only
        case .rspDx, .rspDxR2:
            dp.pointee.rspDxParams.antennaSel = c.antenna == .c ? 2 : c.antenna == .b ? 1 : 0
            dp.pointee.rspDxParams.rfNotchEnable = c.rfNotch ? 1 : 0
            dp.pointee.rspDxParams.rfDabNotchEnable = c.dabNotch ? 1 : 0
            dp.pointee.rspDxParams.biasTEnable = biasTee ? 1 : 0
        case .rsp1, .unknown:
            break
        }
    }

    private func sendUpdate(_ reasons: UInt32, _ ext: UInt32) {
        guard reasons != 0 || ext != 0, let lib = SDRplayLibrary.shared else { return }
        lock.lock()
        guard running else { lock.unlock(); return }
        let dev = device.dev
        let tuner = device.tuner
        lock.unlock()
        _ = lib.update(dev, tuner, reasons, ext)
    }

    fileprivate func stream(_ xi: UnsafeMutablePointer<Int16>, _ xq: UnsafeMutablePointer<Int16>, _ count: Int, reset: Bool) {
        guard let handler else { return }
        if reset { accumulated = 0 }
        var k = 0
        while k < count {
            let take = min(count - k, chunk - accumulated)
            accumulator.withUnsafeMutableBufferPointer { a in
                var o = 2 * accumulated
                for j in k..<(k + take) {
                    a[o] = xi[j]
                    a[o + 1] = xq[j]
                    o += 2
                }
            }
            accumulated += take
            k += take
            if accumulated == chunk {
                accumulator.withUnsafeBufferPointer { handler(.s16($0)) }
                accumulated = 0
            }
        }
    }

    fileprivate func event(_ event: Int32, _ params: UnsafeMutablePointer<ksdrplay_EventParams>?) {
        switch event {
        case 0:   // gain change
            if let gain = params?.pointee.gainParams.currGain { lock.withLock { gainDB = gain } }
        case 1:   // power overload change: must be acknowledged
            let detected = params?.pointee.powerOverloadParams.powerOverloadChangeType == 0
            sendUpdate(SDRplayUpdate.ctrlOverloadAck, 0)
            lock.withLock { overloaded = detected }
        case 2:   // device removed
            onError?("The SDRplay device was disconnected.")
        case 4:   // device failure
            onError?("The SDRplay device stopped working. Reconnect it and start again.")
        default:
            break
        }
    }
}
