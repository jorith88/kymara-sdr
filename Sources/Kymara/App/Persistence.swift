import Foundation
import SDRCore

struct Bookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var frequency: Double
    var mode: DemodMode
    var bandwidth: Double
    var group: String = "General"
}

extension Bookmark {
    /// Tolerant: only the frequency is required; anything else missing or unknown gets a default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try c.decode(Double.self, forKey: .frequency)
        id = c.lenient(UUID.self, .id) ?? UUID()
        mode = c.lenient(DemodMode.self, .mode) ?? .am
        bandwidth = c.lenient(Double.self, .bandwidth) ?? mode.defaultBandwidth
        name = c.lenient(String.self, .name) ?? FrequencyFormat.short(frequency)
        group = c.lenient(String.self, .group) ?? "General"
    }
}

/// Persisted user settings.
struct RadioSettings: Codable {
    var sourceKind: SourceKind = .demo
    var tcpHost = "127.0.0.1"
    var tcpPort = 1234
    var vfo: Double = 100_000_000
    var center: Double = 99_700_000
    var mode: DemodMode = .wfm
    var bandwidths: [String: Double] = [:]
    var steps: [String: Double] = [:]
    var sampleRate: Double = 2_400_000
    var gainAuto = false
    var gain = 297
    var ppm = 0
    var rtlAGC = false
    var directSampling = 0
    var biasTee = false
    var offsetTuning = false
    var volume: Double = 0.5
    var squelchEnabled = false
    var squelchLevel: Double = -50
    var agcMode: AGCMode = .medium
    var afGain: Double = 20
    var deemphasis: Deemphasis = .eu
    var stereo = true
    var rds = true
    var cwPitch: Double = 700
    var dcCorrection = true
    var swapIQ = false
    var fftSize = 16384
    var averaging: Double = 0.5
    var spectrumTop: Double = -10
    var spectrumBottom: Double = -110
    var waterfallMin: Double = -95
    var waterfallMax: Double = -35
    var palette: WaterfallPalette = .classic
    var waterfallSpeed: Double = 30
    var spectrumRate: Double = 40
    var peakHold = false
    var fillSpectrum = true
    var meterCalibration: Double = -10
    var showBookmarks = true
    var theme: AppTheme? = nil
    /// Legacy: favourites used to live in this blob. Read for migration only.
    var bookmarks: [Bookmark]? = nil
}

extension RadioSettings {
    /// Every field is read on its own; a missing, renamed or invalid value falls back to its default
    /// instead of discarding all settings.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = c.lenient(T.self, key) { value = v }
        }
        read(.sourceKind, &sourceKind)
        read(.tcpHost, &tcpHost)
        read(.tcpPort, &tcpPort)
        read(.vfo, &vfo)
        read(.center, &center)
        read(.mode, &mode)
        read(.bandwidths, &bandwidths)
        read(.steps, &steps)
        read(.sampleRate, &sampleRate)
        read(.gainAuto, &gainAuto)
        read(.gain, &gain)
        read(.ppm, &ppm)
        read(.rtlAGC, &rtlAGC)
        read(.directSampling, &directSampling)
        read(.biasTee, &biasTee)
        read(.offsetTuning, &offsetTuning)
        read(.volume, &volume)
        read(.squelchEnabled, &squelchEnabled)
        read(.squelchLevel, &squelchLevel)
        read(.agcMode, &agcMode)
        read(.afGain, &afGain)
        read(.deemphasis, &deemphasis)
        read(.stereo, &stereo)
        read(.rds, &rds)
        read(.cwPitch, &cwPitch)
        read(.dcCorrection, &dcCorrection)
        read(.swapIQ, &swapIQ)
        read(.fftSize, &fftSize)
        read(.averaging, &averaging)
        read(.spectrumTop, &spectrumTop)
        read(.spectrumBottom, &spectrumBottom)
        read(.waterfallMin, &waterfallMin)
        read(.waterfallMax, &waterfallMax)
        read(.palette, &palette)
        read(.waterfallSpeed, &waterfallSpeed)
        read(.spectrumRate, &spectrumRate)
        read(.peakHold, &peakHold)
        read(.fillSpectrum, &fillSpectrum)
        read(.meterCalibration, &meterCalibration)
        read(.showBookmarks, &showBookmarks)
        theme = c.lenient(AppTheme.self, .theme)
        bookmarks = c.lenient(LossyArray<Bookmark>.self, .bookmarks)?.elements
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value, returning nil when it is absent or cannot be decoded.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// Decodes an array, skipping elements that fail instead of failing the whole array.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !c.isAtEnd {
            if let e = try? c.decode(Element.self) {
                out.append(e)
            } else {
                _ = try? c.decode(Skip.self)
            }
        }
        elements = out
    }
}

/// UserDefaults persistence. Settings and favourites are stored under separate keys so a problem
/// with one never costs the other; unreadable data is backed up before it would be overwritten.
struct SettingsStore {
    static let settingsKey = "RadioSettings.v1"
    static let bookmarksKey = "Bookmarks.v1"

    var defaults: UserDefaults = .standard

    func loadSettings() -> RadioSettings? {
        guard let data = defaults.data(forKey: Self.settingsKey) else { return nil }
        if let s = try? JSONDecoder().decode(RadioSettings.self, from: data) { return s }
        backup(data, key: Self.settingsKey)
        return nil
    }

    func saveSettings(_ settings: RadioSettings) {
        var s = settings
        s.bookmarks = nil
        if let data = try? JSONEncoder().encode(s) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    /// Favourites from their own key, else migrated from the legacy settings blob, else nil (first run).
    func loadBookmarks(legacy: [Bookmark]?) -> [Bookmark]? {
        if let data = defaults.data(forKey: Self.bookmarksKey) {
            if let list = try? JSONDecoder().decode(LossyArray<Bookmark>.self, from: data) {
                return list.elements
            }
            backup(data, key: Self.bookmarksKey)
        }
        return legacy
    }

    func saveBookmarks(_ bookmarks: [Bookmark]) {
        if let data = try? JSONEncoder().encode(bookmarks) {
            defaults.set(data, forKey: Self.bookmarksKey)
        }
    }

    private func backup(_ data: Data, key: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        defaults.set(data, forKey: "\(key).unreadable.\(stamp)")
    }
}
