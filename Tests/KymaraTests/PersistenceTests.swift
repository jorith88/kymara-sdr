import XCTest
import SDRCore
@testable import Kymara

final class PersistenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "KymaraTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private var store: SettingsStore { SettingsStore(defaults: defaults) }

    private func storeRawSettings(_ json: String) {
        defaults.set(Data(json.utf8), forKey: SettingsStore.settingsKey)
    }

    func testRoundTrip() {
        var s = RadioSettings()
        s.vfo = 145_500_000
        s.mode = .nfm
        s.palette = .turbo
        s.theme = .light
        s.bandwidths = ["NFM": 12_500]
        store.saveSettings(s)
        let loaded = store.loadSettings()
        XCTAssertEqual(loaded?.vfo, 145_500_000)
        XCTAssertEqual(loaded?.mode, .nfm)
        XCTAssertEqual(loaded?.palette, .turbo)
        XCTAssertEqual(loaded?.theme, .light)
        XCTAssertEqual(loaded?.bandwidths["NFM"], 12_500)
    }

    func testMissingFieldsKeepTheRest() {
        // Simulates settings written by an older version that lacked most fields.
        storeRawSettings(#"{"vfo": 7100000, "mode": "LSB"}"#)
        let s = store.loadSettings()
        XCTAssertEqual(s?.vfo, 7_100_000)
        XCTAssertEqual(s?.mode, .lsb)
        XCTAssertEqual(s?.fftSize, RadioSettings().fftSize)
        XCTAssertNil(s?.theme)
        XCTAssertEqual(s?.showRDSPanel, true, "new settings default when absent")
    }

    func testUnknownOrInvalidValuesFallBackPerField() {
        storeRawSettings(#"{"vfo": 99000000, "palette": "Rainbow", "mode": "FreeDV", "gain": "high", "volume": 0.8, "futureOption": true}"#)
        let s = store.loadSettings()
        XCTAssertEqual(s?.vfo, 99_000_000)
        XCTAssertEqual(s?.volume, 0.8)
        XCTAssertEqual(s?.palette, RadioSettings().palette)
        XCTAssertEqual(s?.mode, RadioSettings().mode)
        XCTAssertEqual(s?.gain, RadioSettings().gain)
    }

    func testCorruptSettingsAreBackedUp() {
        storeRawSettings("this is not json")
        XCTAssertNil(store.loadSettings())
        let backups = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(SettingsStore.settingsKey + ".unreadable.") }
        XCTAssertEqual(backups.count, 1)
    }

    func testBookmarksAreStoredSeparately() {
        let b = [Bookmark(name: "Test", frequency: 145_500_000, mode: .nfm, bandwidth: 12_500, group: "Amateur")]
        var s = RadioSettings()
        s.bookmarks = b
        store.saveSettings(s)
        store.saveBookmarks(b)
        XCTAssertNil(store.loadSettings()?.bookmarks, "settings blob must not carry favourites")
        // Even with the settings blob destroyed, favourites survive.
        storeRawSettings("garbage")
        XCTAssertEqual(store.loadBookmarks(legacy: nil), b)
    }

    func testLegacyBookmarksAreMigrated() {
        storeRawSettings(#"{"vfo": 100000000, "bookmarks": [{"name": "Old", "frequency": 124000000, "mode": "AM", "bandwidth": 8000, "group": "Aviation", "id": "6F1B2C9A-9A57-4D2E-9C0B-0B5A2E2F3A11"}]}"#)
        let s = store.loadSettings()
        let migrated = store.loadBookmarks(legacy: s?.bookmarks)
        XCTAssertEqual(migrated?.count, 1)
        XCTAssertEqual(migrated?.first?.name, "Old")
        XCTAssertEqual(migrated?.first?.group, "Aviation")
    }

    func testBadBookmarksAreSkippedOrRepaired() {
        let json = #"""
        [
          {"name": "Good", "frequency": 100000000, "mode": "WFM", "bandwidth": 180000},
          {"name": "Unknown mode", "frequency": 14074000, "mode": "FT8"},
          {"name": "No frequency", "mode": "AM"}
        ]
        """#
        defaults.set(Data(json.utf8), forKey: SettingsStore.bookmarksKey)
        let list = store.loadBookmarks(legacy: nil)
        XCTAssertEqual(list?.map(\.name), ["Good", "Unknown mode"])
        XCTAssertEqual(list?[1].mode, .am)
        XCTAssertEqual(list?[1].bandwidth, DemodMode.am.defaultBandwidth)
        XCTAssertEqual(list?[0].group, "General")
    }

    func testFirstRunHasNoSettings() {
        XCTAssertNil(store.loadSettings())
        XCTAssertNil(store.loadBookmarks(legacy: nil))
    }
}
