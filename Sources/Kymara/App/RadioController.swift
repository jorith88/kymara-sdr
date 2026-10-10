import Foundation
import SwiftUI
import Observation
import SDRCore

enum SourceKind: String, CaseIterable, Identifiable, Codable {
    case rtlsdr = "RTL-SDR (USB)"
    case sdrplay = "SDRplay RSP (USB)"
    case rtltcp = "rtl_tcp (network)"
    case demo = "Demo generator"
    case file = "I/Q file"
    var id: String { rawValue }
}

enum Deemphasis: String, CaseIterable, Identifiable, Codable {
    case off = "Off"
    case eu = "50 µs"
    case us = "75 µs"
    var id: String { rawValue }
    var tau: Double {
        switch self {
        case .off: return 0
        case .eu: return 50e-6
        case .us: return 75e-6
        }
    }
}


@MainActor
@Observable
final class RadioController {
    static let sampleRates: [Double] = [250_000, 1_024_000, 1_400_000, 1_800_000, 1_920_000, 2_048_000, 2_400_000, 2_560_000, 2_880_000, 3_200_000]
    static let steps: [Double] = [1, 10, 50, 100, 500, 1_000, 2_500, 5_000, 6_250, 8_330, 9_000, 10_000, 12_500, 25_000, 50_000, 100_000, 200_000, 1_000_000]

    @ObservationIgnored let engine = DSPEngine()
    @ObservationIgnored private lazy var audioOut = AudioOutput(ring: engine.audioRing)
    @ObservationIgnored private var source: IQSource?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loading = true
    @ObservationIgnored private var restarting = false
    @ObservationIgnored private var meterTick = 0
    @ObservationIgnored private var needsInitialAutoRange = false
    /// Width of the waterfall in drawable pixels, set by `WaterfallRenderer` (for auto range).
    @ObservationIgnored var waterfallPixelWidth: Double = 1600

    // MARK: Source
    var sourceKind: SourceKind = .demo { didSet { if sourceKind != oldValue { sourceChanged() } } }
    var rtlDevices: [RTLDeviceInfo] = []
    var selectedDevice: UInt32 = 0
    var tcpHost = "127.0.0.1" { didSet { scheduleSave() } }
    var tcpPort = 1234 { didSet { scheduleSave() } }
    var fileURL: URL?
    private(set) var isRunning = false
    private(set) var sourceName = "Not running"
    var errorMessage: String?
    let libraryPath: String? = RTLSDRSource.libraryPath
    let sdrplayLibraryPath: String? = SDRplaySource.libraryPath
    var sdrplayDevices: [SDRplayDeviceInfo] = []
    var selectedSDRplaySerial = "" { didSet { scheduleSave() } }
    var sdrplay = SDRplayConfig() { didSet { if sdrplay != oldValue { sdrplayChanged() } } }
    /// Model of the running or selected SDRplay device.
    private(set) var sdrplayModel: SDRplayModel?
    private(set) var lnaStateCount = 4
    @ObservationIgnored private var sdrplayGainDB: Double?

    // MARK: Tuning
    private(set) var vfoFrequency: Double = 100_000_000 {
        didSet { if vfoFrequency != oldValue { clearRDS() } }
    }
    private(set) var centerFrequency: Double = 99_700_000
    var mode: DemodMode = .wfm { didSet { if mode != oldValue { modeChanged(from: oldValue) } } }
    var bandwidth: Double = 180_000 { didSet { bandwidths[mode.rawValue] = bandwidth; pushConfig() } }
    var step: Double = 100_000 { didSet { steps[mode.rawValue] = step; scheduleSave() } }
    @ObservationIgnored private var bandwidths: [String: Double] = [:]
    @ObservationIgnored private var steps: [String: Double] = [:]

    // MARK: RF
    var sampleRate: Double = 2_400_000 { didSet { if sampleRate != oldValue { sampleRateChanged() } } }
    private(set) var gains: [Int] = TunerGains.r820t
    var gainAuto = false { didSet { applyGain() } }
    var gain = 297 { didSet { applyGain() } }
    var ppm = 0 { didSet { source?.setPPM(ppm); scheduleSave() } }
    var rtlAGC = false { didSet { source?.setRTLAGC(rtlAGC); scheduleSave() } }
    var directSampling = 0 { didSet { source?.setDirectSampling(directSampling); scheduleSave() } }
    var biasTee = false { didSet { source?.setBiasTee(biasTee); scheduleSave() } }
    var offsetTuning = false { didSet { source?.setOffsetTuning(offsetTuning); scheduleSave() } }
    var dcCorrection = true { didSet { pushConfig() } }
    var swapIQ = false { didSet { pushConfig() } }

    // MARK: Audio / demodulation
    var volume: Double = 0.5 { didSet { pushConfig() } }
    var muted = false { didSet { pushConfig() } }
    var squelchEnabled = false { didSet { pushConfig() } }
    var squelchLevel: Double = -50 { didSet { pushConfig() } }
    /// FM modes only; other modes keep using the level.
    var squelchAuto = false { didSet { pushConfig() } }
    /// Auto squelch is in effect (rather than the level threshold).
    var autoSquelchActive: Bool { squelchEnabled && squelchAuto && (mode == .nfm || mode == .wfm) }
    var agcMode: AGCMode = .medium { didSet { pushConfig() } }
    var afGain: Double = 20 { didSet { pushConfig() } }
    /// Only applied in modes where `DemodMode.supportsAutoNotch`.
    var autoNotch = false { didSet { pushConfig() } }
    /// Sideband for RADE; auto follows the FreeDV convention for the VFO frequency.
    var radeSideband: RADESideband = .auto { didSet { pushConfig() } }
    /// Whether the current RADE reception is in LSB.
    var radeLSB: Bool { mode == .rade && radeSideband.isLSB(at: vfoFrequency) }
    /// The mode as shown to the user, with the sideband for RADE.
    var modeLabel: String { mode == .rade ? "RADE " + (radeLSB ? "LSB" : "USB") : mode.rawValue }
    var deemphasis: Deemphasis = .eu { didSet { pushConfig() } }
    var stereoEnabled = true { didSet { pushConfig() } }
    var rdsEnabled = true { didSet { pushConfig() } }
    var cwPitch: Double = 700 { didSet { pushConfig() } }

    // MARK: Display
    var fftSize = 16384 { didSet { pushConfig() } }
    var averaging: Double = 0.5 { didSet { pushConfig() } }
    var spectrumRate: Double = 40 { didSet { pushConfig() } }
    var spectrumTop: Double = -10 { didSet { scheduleSave() } }
    var spectrumBottom: Double = -110 { didSet { scheduleSave() } }
    var waterfallMin: Double = -95 { didSet { scheduleSave() } }
    var waterfallMax: Double = -35 { didSet { scheduleSave() } }
    var palette: WaterfallPalette = .classic { didSet { scheduleSave() } }
    var waterfallSpeed: Double = 30 { didSet { pushConfig() } }
    var peakHold = false { didSet { scheduleSave() } }
    var fillSpectrum = true { didSet { scheduleSave() } }
    var showBookmarks = true { didSet { scheduleSave() } }
    var sidePanelTab: SidePanelTab = .favourites { didSet { scheduleSave() } }
    var showDXLabels = true { didSet { scheduleSave() } }
    var showRDSPanel = true { didSet { scheduleSave() } }
    /// Spectrum share of the spectrum + waterfall height.
    var spectrumFraction: Double = 320.0 / 740.0 { didSet { scheduleSave() } }
    var theme: AppTheme = .system { didSet { theme.apply(); scheduleSave() } }
    var displayTheme: DisplayTheme = .auto { didSet { scheduleSave() } }
    /// Visible span = sampleRate / zoom.
    private(set) var zoom: Double = 1
    /// View centre relative to the tuner centre frequency.
    private(set) var viewOffset: Double = 0
    var hover: (frequency: Double, db: Double?)?
    var showFrequencyEntry = false

    // MARK: Meter
    private(set) var signalDB: Double = -150
    private(set) var signalPeakDB: Double = -150
    private(set) var squelchOpen = false
    /// Carrier-to-noise estimate in FM modes.
    private(set) var snrDB: Double?
    private(set) var stereoLocked = false
    private(set) var rds = RDSInfo()
    /// FreeDV RADE decoder state (RADE mode only).
    private(set) var rade: RADEStatus?
    /// Callsign from the last RADE end-of-over on this frequency.
    private(set) var radeCallsign: String?
    @ObservationIgnored private var radeCallsignCount = 0
    private(set) var overload = false
    private(set) var audioLatency: Double = 0
    private(set) var measuredRate: Double = 0
    var meterCalibration: Double = -10 { didSet { scheduleSave() } }

    // MARK: Recording
    private(set) var recordingAudio = false
    private(set) var recordingIQ = false
    private(set) var recordingStart: Date?
    var lastRecordingURL: URL?

    // MARK: Bookmarks
    var bookmarks: [Bookmark] = [] { didSet { scheduleSave() } }

    init() {
        load()
        refreshDevices()
        pushConfig()
        loading = false
        engine.recorder.onAutoStop = { [weak self] msg in
            Task { @MainActor in
                self?.recordingIQ = false
                self?.errorMessage = msg
            }
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMeter() }
        }
    }

    // MARK: - Derived values

    var viewSpan: Double { sampleRate / zoom }
    var viewStart: Double { centerFrequency + viewOffset - viewSpan / 2 }
    var viewEnd: Double { centerFrequency + viewOffset + viewSpan / 2 }
    var filterEdges: (lo: Double, hi: Double) { mode.filterEdges(bandwidth: bandwidth, lsb: radeLSB) }
    var filterStart: Double { vfoFrequency + filterEdges.lo }
    var filterEnd: Double { vfoFrequency + filterEdges.hi }
    /// Where the passband would land if the user clicked at the hover position. Nil over the current
    /// passband (a click there drags it instead of tuning) and while a mouse button is held.
    var hoverPassband: (lo: Double, hi: Double)? {
        guard let hover, NSEvent.pressedMouseButtons == 0,
              hover.frequency < filterStart || hover.frequency > filterEnd else { return nil }
        let f = snapped(hover.frequency)
        return (f + filterEdges.lo, f + filterEdges.hi)
    }
    var audioRate: Double { DSPEngine.rates(for: sampleRate).audioRate }
    var canRetune: Bool { source?.fixedCenterFrequency == nil || !isRunning }
    var gainDB: Double {
        if sourceKind == .sdrplay { return sdrplayGainDB ?? 40 }
        return gainAuto ? 30 : Double(gain) / 10
    }
    /// Sample rates offered for the current source.
    var sampleRateChoices: [Double] {
        sourceKind == .sdrplay ? SDRplayRatePlan.outputRates : Self.sampleRates
    }
    var signalDBm: Double { signalDB - gainDB + meterCalibration }
    var maxBandwidth: Double {
        mode == .wfm ? min(mode.bandwidthRange.upperBound, 0.92 * DSPEngine.rates(for: sampleRate).rate1)
                     : min(mode.bandwidthRange.upperBound, 0.84 * audioRate)
    }

    // MARK: - Source control

    func refreshDevices() {
        rtlDevices = RTLSDRSource.listDevices()
        if !rtlDevices.contains(where: { $0.index == selectedDevice }) {
            selectedDevice = rtlDevices.first?.index ?? 0
        }
        // Only talk to the SDRplay API service when it is used. A running SDRplay device is not listed
        // by the API, so keep the list as it is meanwhile.
        if sourceKind == .sdrplay, !(source is SDRplaySource) {
            sdrplayDevices = SDRplaySource.listDevices()
            if !sdrplayDevices.contains(where: { $0.serial == selectedSDRplaySerial }), let first = sdrplayDevices.first {
                selectedSDRplaySerial = first.serial
            }
            updateSDRplayModel()
        }
    }

    private func updateSDRplayModel() {
        if let sp = source as? SDRplaySource {
            sdrplayModel = sp.model
            lnaStateCount = sp.lnaStateCount
        } else if let dev = sdrplayDevices.first(where: { $0.serial == selectedSDRplaySerial }) {
            sdrplayModel = dev.model
            lnaStateCount = dev.model.lnaStateCount(frequency: centerFrequency, antenna: sdrplay.antenna)
        }
    }

    func toggleRunning() {
        isRunning ? stop() : start()
    }

    func start() {
        stopSource()
        let src: IQSource
        do {
            switch sourceKind {
            case .rtlsdr:
                guard RTLSDRSource.isLibraryAvailable else { throw SourceError.libraryMissing }
                refreshDevices()
                guard let dev = rtlDevices.first(where: { $0.index == selectedDevice }) ?? rtlDevices.first else {
                    throw SourceError.noDevice
                }
                src = RTLSDRSource(deviceIndex: dev.index, name: dev.label)
            case .sdrplay:
                guard SDRplaySource.isLibraryAvailable else { throw SourceError.sdrplayAPIMissing }
                refreshDevices()
                guard let dev = sdrplayDevices.first(where: { $0.serial == selectedSDRplaySerial }) ?? sdrplayDevices.first else {
                    throw SourceError.noSDRplayDevice
                }
                selectedSDRplaySerial = dev.serial
                src = SDRplaySource(serial: dev.serial, config: sdrplay)
            case .rtltcp:
                src = RTLTCPSource(host: tcpHost, port: UInt16(clamping: tcpPort))
            case .demo:
                src = DemoSource()
            case .file:
                guard let fileURL else { throw SourceError.fileError("choose a file first") }
                src = try FileSource(url: fileURL)
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        src.onError = { [weak self] msg in
            Task { @MainActor in
                self?.errorMessage = msg
                self?.stop()
            }
        }
        src.onInfoChanged = { [weak self, weak src] in
            Task { @MainActor in
                guard let self, let src, self.source === src else { return }
                self.gains = src.gains.isEmpty ? self.gains : src.gains
                self.sourceName = src.displayName
                self.updateSDRplayModel()
            }
        }

        restarting = true
        if let rate = src.fixedSampleRate { sampleRate = rate }
        if let rates = src.sampleRates { sampleRate = Self.nearest(sampleRate, in: rates) }
        if let center = src.fixedCenterFrequency {
            centerFrequency = center
            if abs(vfoFrequency - center) > sampleRate * 0.45 { vfoFrequency = center + sampleRate / 8 }
        }
        restarting = false

        src.setPPM(ppm)
        src.setRTLAGC(rtlAGC)
        src.setDirectSampling(directSampling)
        src.setOffsetTuning(offsetTuning)
        src.setBiasTee(biasTee)
        src.setGain(gainAuto ? nil : gain)

        pushConfig()
        engine.reset()
        do {
            try audioOut.start(sampleRate: audioRate)
        } catch {
            errorMessage = "Audio output failed: \(error.localizedDescription)"
        }
        let engine = self.engine
        do {
            try src.start(sampleRate: sampleRate, centerFrequency: centerFrequency) { buffer in
                engine.process(buffer)
            }
        } catch {
            audioOut.stop()
            errorMessage = error.localizedDescription
            return
        }
        source = src
        if !src.gains.isEmpty {
            gains = src.gains
            if !gains.contains(gain) { gain = nearestGain(gain) }
        }
        sourceName = src.displayName
        updateSDRplayModel()
        isRunning = true
        if needsInitialAutoRange {
            needsInitialAutoRange = false
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.autoRange()
            }
        }
    }

    func stop() {
        stopRecordingAll()
        stopSource()
        audioOut.stop()
        isRunning = false
        clearRDS()
        sourceName = "Not running"
        signalDB = -150
    }

    private func stopSource() {
        source?.stop()
        source = nil
    }

    private func restartIfRunning() {
        guard isRunning, !restarting else { return }
        start()
    }

    private func sourceChanged() {
        if isRunning { stop() }
        if sourceKind != .file { sampleRate = Self.nearest(sampleRate, in: sampleRateChoices) }
        if sourceKind == .sdrplay, !loading { refreshDevices() }
        scheduleSave()
    }

    private static func nearest(_ rate: Double, in rates: [Double]) -> Double {
        rates.min { abs($0 - rate) < abs($1 - rate) } ?? rate
    }

    private func sdrplayChanged() {
        if let sp = source as? SDRplaySource {
            if sp.configure(sdrplay) { restartIfRunning() }
        }
        updateSDRplayModel()
        scheduleSave()
    }

    private func sampleRateChanged() {
        clampView()
        if bandwidth > maxBandwidth { bandwidth = maxBandwidth }
        if abs(vfoFrequency - centerFrequency) > sampleRate * 0.48 { vfoFrequency = centerFrequency }
        pushConfig()
        restartIfRunning()
    }

    private func nearestGain(_ g: Int) -> Int {
        gains.min { abs($0 - g) < abs($1 - g) } ?? g
    }

    private func applyGain() {
        source?.setGain(gainAuto ? nil : gain)
        scheduleSave()
    }

    // MARK: - Tuning

    /// Tunes the VFO. Moves the tuner centre when the VFO would leave the usable band.
    /// `follow`: shift the band just enough (scrolling); otherwise jump so the VFO sits right of centre.
    func tune(to frequency: Double, follow: Bool = false) {
        let f = min(max(frequency, 0), 2_200_000_000)
        let usable = sampleRate * 0.46
        let margin = min(bandwidth / 2, usable / 2)
        if !canRetune {
            vfoFrequency = min(max(f, centerFrequency - usable + margin), centerFrequency + usable - margin)
        } else if abs(f - centerFrequency) > usable - margin {
            vfoFrequency = f
            if follow {
                let newCenter = f > centerFrequency ? f - (usable - margin) : f + (usable - margin)
                setCenterInternal(newCenter)
            } else {
                // Keep the signal away from the DC spike.
                setCenterInternal(f - sampleRate / 8)
            }
        } else {
            vfoFrequency = f
        }
        ensureVFOVisible()
        pushConfig()
    }

    func tuneSteps(_ n: Int) {
        let snapped = (vfoFrequency / step).rounded() * step
        tune(to: snapped + Double(n) * step, follow: true)
    }

    func snapped(_ f: Double) -> Double {
        step >= 1 ? (f / step).rounded() * step : f
    }

    func setCenterFrequency(_ f: Double) {
        guard canRetune else { return }
        setCenterInternal(min(max(f, 0), 2_200_000_000))
        let usable = sampleRate * 0.46
        if abs(vfoFrequency - centerFrequency) > usable {
            vfoFrequency = min(max(vfoFrequency, centerFrequency - usable), centerFrequency + usable)
        }
        pushConfig()
    }

    private func setCenterInternal(_ f: Double) {
        centerFrequency = f.rounded()
        source?.setCenterFrequency(centerFrequency)
        clampView()
    }

    func setBandwidth(_ bw: Double) {
        let r = mode.bandwidthRange
        bandwidth = min(max(bw, r.lowerBound), maxBandwidth).rounded()
    }

    private func clearRDS() {
        engine.resetRDS()
        if rds != RDSInfo() { rds = RDSInfo() }
        // The callsign belongs to the station just left, as RDS does.
        if radeCallsign != nil { radeCallsign = nil }
    }

    private func modeChanged(from old: DemodMode) {
        clearRDS()
        bandwidths[old.rawValue] = bandwidth
        steps[old.rawValue] = step
        let bw = bandwidths[mode.rawValue] ?? mode.defaultBandwidth
        bandwidth = min(bw, maxBandwidth)
        step = steps[mode.rawValue] ?? mode.defaultStep
        pushConfig()
    }

    // MARK: - View (zoom / pan)

    func setZoom(_ z: Double, anchor: Double? = nil) {
        let newZoom = min(max(z, 1), 256)
        let anchorFreq = anchor ?? (vfoFrequency)
        // Keep the anchor frequency at the same relative screen position.
        let rel = (anchorFreq - viewStart) / viewSpan
        zoom = newZoom
        let newStart = anchorFreq - rel * viewSpan
        viewOffset = newStart + viewSpan / 2 - centerFrequency
        clampView()
    }

    func pan(by hz: Double) {
        viewOffset += hz
        clampView()
    }

    func resetView() {
        zoom = 1
        viewOffset = 0
    }

    private func clampView() {
        let limit = (sampleRate - viewSpan) / 2
        viewOffset = min(max(viewOffset, -limit), limit)
    }

    private func ensureVFOVisible() {
        guard zoom > 1 else { return }
        let lo = filterStart, hi = filterEnd
        if lo < viewStart || hi > viewEnd {
            viewOffset = vfoFrequency - centerFrequency
            clampView()
        }
    }

    func autoRange() {
        engine.spectrum.withLatest { spectrum, _, _ in
            guard spectrum.count > 16 else { return }
            let sorted = spectrum.sorted()
            let noise = Double(sorted[sorted.count / 5])
            let top = Double(sorted[sorted.count - 1 - sorted.count / 500])
            spectrumBottom = (noise - 15).rounded()
            spectrumTop = max(spectrumBottom + 30, (top + 10).rounded())
        }
        autoRangeWaterfall()
    }

    /// Sets the waterfall levels from what it actually shows: raw (unaveraged) lines over the visible
    /// span, reduced to the maximum per pixel like the shader does. Both lift the noise well above the
    /// averaged spectrum's floor.
    private func autoRangeWaterfall() {
        let lines = engine.spectrum.recentLines()
        guard let count = lines.last?.count, count > 16 else { return }
        let bandStart = centerFrequency - sampleRate / 2
        let lo = max(0, Int((viewStart - bandStart) / sampleRate * Double(count)))
        let hi = min(count, Int((viewEnd - bandStart) / sampleRate * Double(count)))
        let group = max(1, Int((Double(hi - lo) / max(waterfallPixelWidth, 1)).rounded()))
        var pixels: [Float] = []
        pixels.reserveCapacity(lines.count * (hi - lo) / group)
        for line in lines where line.count == count {
            var i = lo
            while i + group <= hi {
                var m = line[i]
                for j in i + 1 ..< i + group where line[j] > m { m = line[j] }
                pixels.append(m)
                i += group
            }
        }
        guard pixels.count > 16 else { return }
        pixels.sort()
        let noise = Double(pixels[pixels.count / 5])
        let top = Double(pixels[pixels.count - 1 - pixels.count / 1000])
        // The noise floor lands low in the palette (dark, still textured); the strongest signal near the top.
        waterfallMin = (noise - 6).rounded()
        waterfallMax = max(waterfallMin + 35, (top + 3).rounded())
    }

    // MARK: - Config / meter

    private func pushConfig() {
        var c = DSPConfig()
        c.sampleRate = sampleRate
        c.vfoOffset = vfoFrequency - centerFrequency
        c.mode = mode
        c.bandwidth = bandwidth
        c.squelchEnabled = squelchEnabled
        c.squelchLevel = Float(squelchLevel)
        c.squelchAuto = squelchAuto
        c.agcMode = agcMode
        c.afGainDB = Float(afGain)
        c.autoNotch = autoNotch
        c.radeLSB = radeLSB
        // Perceptual volume curve.
        c.volume = Float(volume * volume)
        c.muted = muted
        c.deemphasis = deemphasis.tau
        c.stereo = stereoEnabled
        c.rds = rdsEnabled
        c.cwPitch = cwPitch
        c.dcCorrection = dcCorrection
        c.swapIQ = swapIQ
        c.fftSize = fftSize
        c.spectrumRate = spectrumRate
        c.waterfallRate = waterfallSpeed
        c.averaging = Float(averaging)
        engine.config = c
        scheduleSave()
    }

    private func updateMeter() {
        guard isRunning else { return }
        let s = engine.status
        let level = Double(s.levelDB)
        // Fast attack, slow release, like an analogue meter.
        signalDB = level > signalDB ? signalDB + (level - signalDB) * 0.6 : signalDB + (level - signalDB) * 0.12
        signalPeakDB = max(signalPeakDB - 0.25, signalDB)
        if squelchOpen != s.squelchOpen { squelchOpen = s.squelchOpen }
        let snr = s.snrDB.map { Double($0.rounded()) }
        if snrDB != snr { snrDB = snr }
        if stereoLocked != s.stereoLocked { stereoLocked = s.stereoLocked }
        let radeStatus = s.rade.map { r in
            var r = r
            r.snrDB = r.snrDB.rounded()
            r.frequencyOffset = r.frequencyOffset.rounded()
            return r
        }
        if rade != radeStatus { rade = radeStatus }
        // The count restarts at 0 when the engine builds a new decoder, so any change to a non-zero count is news.
        if let s = s.rade, s.callsignCount != radeCallsignCount {
            if s.callsignCount > 0, let call = s.callsign, !call.isEmpty { radeCallsign = call }
            radeCallsignCount = s.callsignCount
        }
        let isOverloaded = s.overload || (source?.hardwareOverload ?? false)
        if overload != isOverloaded { overload = isOverloaded }
        sdrplayGainDB = (source as? SDRplaySource)?.systemGainDB
        meterTick &+= 1
        if meterTick % 5 == 0, s.rds != rds { rds = s.rds }
        if meterTick % 15 == 0 {
            audioLatency = engine.audioRing.latency
            measuredRate = s.samplesPerSecond
        }
    }

    // MARK: - Recording

    static var recordingsFolder: URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = base.appendingPathComponent("Kymara Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func showRecordingsInFinder() {
        NSWorkspace.shared.open(Self.recordingsFolder)
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    func toggleAudioRecording() {
        if recordingAudio {
            engine.recorder.stopAudio()
            recordingAudio = false
            lastRecordingURL = engine.recorder.audioURL
            return
        }
        guard isRunning else { errorMessage = "Start the radio before recording."; return }
        let name = "Audio_\(timestamp())_\(Int(vfoFrequency))Hz_\(mode.rawValue).wav"
        let url = Self.recordingsFolder.appendingPathComponent(name)
        do {
            try engine.recorder.startAudio(url: url, sampleRate: audioRate)
            recordingAudio = true
            recordingStart = Date()
        } catch {
            errorMessage = "Cannot record audio: \(error.localizedDescription)"
        }
    }

    func toggleIQRecording() {
        if recordingIQ {
            engine.recorder.stopIQ()
            recordingIQ = false
            lastRecordingURL = engine.recorder.iqURL
            return
        }
        guard isRunning else { errorMessage = "Start the radio before recording."; return }
        let name = "IQ_\(timestamp())_\(Int(centerFrequency))Hz_\(Int(sampleRate))sps.wav"
        let url = Self.recordingsFolder.appendingPathComponent(name)
        do {
            try engine.recorder.startIQ(url: url, sampleRate: sampleRate, bitsPerSample: source?.sampleBits ?? 8)
            recordingIQ = true
            recordingStart = Date()
        } catch {
            errorMessage = "Cannot record I/Q: \(error.localizedDescription)"
        }
    }

    private func stopRecordingAll() {
        if recordingAudio { toggleAudioRecording() }
        if recordingIQ { toggleIQRecording() }
    }

    // MARK: - Bookmarks

    func addBookmark(name: String? = nil, group: String = "General") {
        let stationName = mode == .wfm && rds.hasData ? rds.trimmedProgramService : ""
        let label = name ?? (stationName.isEmpty ? String(format: "%.4f MHz %@", vfoFrequency / 1e6, mode.rawValue)
                                                 : String(format: "%@ %.1f", stationName, vfoFrequency / 1e6))
        bookmarks.append(Bookmark(name: label, frequency: vfoFrequency, mode: mode, bandwidth: bandwidth, group: group))
    }

    func recall(_ b: Bookmark) {
        mode = DemodMode.available.contains(b.mode) ? b.mode : .usb
        bandwidth = min(b.bandwidth, maxBandwidth)
        jump(to: b.frequency)
    }

    /// Tunes to a DX spot in its mode, keeping the bandwidth last used in that mode.
    func tune(to spot: DXSpot) {
        mode = spot.demodMode
        jump(to: spot.frequency)
    }

    func addBookmark(_ spot: DXSpot) {
        let mode = spot.demodMode
        let bw = mode == self.mode ? bandwidth : min(bandwidths[mode.rawValue] ?? mode.defaultBandwidth, maxBandwidth)
        bookmarks.append(Bookmark(name: spot.dxCall, frequency: spot.frequency, mode: mode, bandwidth: bw, group: "DX"))
    }

    /// Tunes to a picked frequency (a favourite or a spot). When zoomed in, the view stays put if the
    /// frequency is already in it, and is centred on it otherwise or when the LO had to move.
    private func jump(to frequency: Double) {
        let inView = (viewStart...viewEnd).contains(frequency)
        let oldCenter = centerFrequency
        tune(to: frequency, follow: inView)
        if zoom > 1 && (!inView || centerFrequency != oldCenter) {
            viewOffset = vfoFrequency - centerFrequency
            clampView()
        }
    }

    static let defaultBookmarks: [Bookmark] = [
        Bookmark(name: "FM broadcast 100.0", frequency: 100_000_000, mode: .wfm, bandwidth: 180_000, group: "Broadcast"),
        Bookmark(name: "FM broadcast 101.2", frequency: 101_200_000, mode: .wfm, bandwidth: 180_000, group: "Broadcast"),
        Bookmark(name: "Airband 124.000", frequency: 124_000_000, mode: .am, bandwidth: 8_000, group: "Aviation"),
        Bookmark(name: "Airband 124.325", frequency: 124_325_000, mode: .am, bandwidth: 8_000, group: "Aviation"),
        Bookmark(name: "Air distress 121.5", frequency: 121_500_000, mode: .am, bandwidth: 8_000, group: "Aviation"),
        Bookmark(name: "2 m calling 145.500", frequency: 145_500_000, mode: .nfm, bandwidth: 12_500, group: "Amateur"),
        Bookmark(name: "70 cm calling 433.500", frequency: 433_500_000, mode: .nfm, bandwidth: 12_500, group: "Amateur"),
        Bookmark(name: "40 m SSB 7.100", frequency: 7_100_000, mode: .lsb, bandwidth: 2_700, group: "Amateur"),
        Bookmark(name: "20 m SSB 14.200", frequency: 14_200_000, mode: .usb, bandwidth: 2_700, group: "Amateur"),
        Bookmark(name: "20 m CW 14.060", frequency: 14_060_000, mode: .cw, bandwidth: 500, group: "Amateur"),
        Bookmark(name: "Marine ch 16", frequency: 156_800_000, mode: .nfm, bandwidth: 12_500, group: "Marine"),
        Bookmark(name: "PMR446 ch 1", frequency: 446_006_250, mode: .nfm, bandwidth: 10_000, group: "PMR"),
        Bookmark(name: "ISM 433.92", frequency: 433_920_000, mode: .am, bandwidth: 10_000, group: "ISM"),
    ]

    // MARK: - Persistence

    private func load() {
        let store = SettingsStore()
        var s: RadioSettings
        if let loaded = store.loadSettings() {
            s = loaded
        } else {
            s = RadioSettings()
            needsInitialAutoRange = true
            s.sourceKind = !RTLSDRSource.listDevices().isEmpty ? .rtlsdr
                : !SDRplaySource.listDevices().isEmpty ? .sdrplay : .demo
        }
        sourceKind = s.sourceKind
        tcpHost = s.tcpHost
        tcpPort = s.tcpPort
        selectedSDRplaySerial = s.sdrplaySerial
        sdrplay = s.sdrplay
        bandwidths = s.bandwidths
        steps = s.steps
        sampleRate = s.sampleRate
        // A mode this build lacks (RADE without its sources) falls back to its sideband.
        let savedMode = DemodMode.available.contains(s.mode) ? s.mode : .usb
        mode = savedMode
        bandwidth = s.bandwidths[savedMode.rawValue] ?? savedMode.defaultBandwidth
        step = s.steps[savedMode.rawValue] ?? savedMode.defaultStep
        centerFrequency = s.center
        vfoFrequency = s.vfo
        gainAuto = s.gainAuto
        gain = s.gain
        ppm = s.ppm
        rtlAGC = s.rtlAGC
        directSampling = s.directSampling
        biasTee = s.biasTee
        offsetTuning = s.offsetTuning
        volume = s.volume
        squelchEnabled = s.squelchEnabled
        squelchLevel = s.squelchLevel
        squelchAuto = s.squelchAuto
        agcMode = s.agcMode
        autoNotch = s.autoNotch
        radeSideband = s.radeSideband
        afGain = s.afGain
        deemphasis = s.deemphasis
        stereoEnabled = s.stereo
        rdsEnabled = s.rds
        cwPitch = s.cwPitch
        dcCorrection = s.dcCorrection
        swapIQ = s.swapIQ
        fftSize = SpectrumAnalyzer.sizes.contains(s.fftSize) ? s.fftSize : 16384
        averaging = s.averaging
        spectrumTop = s.spectrumTop
        spectrumBottom = s.spectrumBottom
        waterfallMin = s.waterfallMin
        waterfallMax = s.waterfallMax
        palette = s.palette
        waterfallSpeed = s.waterfallSpeed
        spectrumRate = s.spectrumRate
        peakHold = s.peakHold
        fillSpectrum = s.fillSpectrum
        meterCalibration = s.meterCalibration
        showBookmarks = s.showBookmarks
        sidePanelTab = s.sidePanelTab
        showDXLabels = s.showDXLabels
        showRDSPanel = s.showRDSPanel
        spectrumFraction = min(max(s.spectrumFraction, 0.05), 0.95)
        displayTheme = s.displayTheme
        theme = s.theme ?? .system
        theme.apply()
        bookmarks = store.loadBookmarks(legacy: s.bookmarks) ?? Self.defaultBookmarks
        if abs(vfoFrequency - centerFrequency) > sampleRate * 0.48 { centerFrequency = vfoFrequency - sampleRate / 8 }
    }

    private func currentSettings() -> RadioSettings {
        var s = RadioSettings()
        s.sourceKind = sourceKind
        s.tcpHost = tcpHost
        s.tcpPort = tcpPort
        s.sdrplaySerial = selectedSDRplaySerial
        s.sdrplay = sdrplay
        s.vfo = vfoFrequency
        s.center = centerFrequency
        s.mode = mode
        var bw = bandwidths
        bw[mode.rawValue] = bandwidth
        s.bandwidths = bw
        var st = steps
        st[mode.rawValue] = step
        s.steps = st
        s.sampleRate = sampleRate
        s.gainAuto = gainAuto
        s.gain = gain
        s.ppm = ppm
        s.rtlAGC = rtlAGC
        s.directSampling = directSampling
        s.biasTee = biasTee
        s.offsetTuning = offsetTuning
        s.volume = volume
        s.squelchEnabled = squelchEnabled
        s.squelchLevel = squelchLevel
        s.squelchAuto = squelchAuto
        s.agcMode = agcMode
        s.autoNotch = autoNotch
        s.radeSideband = radeSideband
        s.afGain = afGain
        s.deemphasis = deemphasis
        s.stereo = stereoEnabled
        s.rds = rdsEnabled
        s.cwPitch = cwPitch
        s.dcCorrection = dcCorrection
        s.swapIQ = swapIQ
        s.fftSize = fftSize
        s.averaging = averaging
        s.spectrumTop = spectrumTop
        s.spectrumBottom = spectrumBottom
        s.waterfallMin = waterfallMin
        s.waterfallMax = waterfallMax
        s.palette = palette
        s.waterfallSpeed = waterfallSpeed
        s.spectrumRate = spectrumRate
        s.peakHold = peakHold
        s.fillSpectrum = fillSpectrum
        s.meterCalibration = meterCalibration
        s.showBookmarks = showBookmarks
        s.sidePanelTab = sidePanelTab
        s.showDXLabels = showDXLabels
        s.showRDSPanel = showRDSPanel
        s.spectrumFraction = spectrumFraction
        s.displayTheme = displayTheme
        s.theme = theme
        return s
    }

    private func scheduleSave() {
        guard !loading else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let store = SettingsStore()
        store.saveSettings(currentSettings())
        store.saveBookmarks(bookmarks)
    }
}
