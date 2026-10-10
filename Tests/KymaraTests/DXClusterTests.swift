import XCTest
import SDRCore
@testable import Kymara

final class DXClusterTests: XCTestCase {
    /// 2026-10-10 06:00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_612_000)

    private func utc(_ hh: Int, _ mm: Int, daysAgo: Int = 0) -> Date {
        now.addingTimeInterval(Double((hh - 6) * 3_600 + mm * 60 - daysAgo * 86_400))
    }

    // Real entries from DXHeat, plus malformed ones that must be skipped.
    private let sample = #"""
    [{"Nr": 68003611, "Spotter": "JF1KKV", "Frequency": "10136.0", "DXCall": "8N0CC/P", "Time": "05:52",
      "Date": "10/10/26", "Beacon": false, "MM": false, "AM": false, "Valid": true, "DXHomecall": "8N0CC",
      "Comment": "ft8 cq cq 778hz.", "Flag": "jp", "Band": 30.0, "Mode": "DIGITAL", "Continent_dx": "AS",
      "Continent_spotter": "AS", "DXLocator": "PM95VQ"},
     {"Nr": 68003610, "Spotter": "IK4RTYT", "Frequency": "21084.5", "DXCall": "3V8LL", "Time": "05:52",
      "Date": "10/10/26", "Valid": true, "LOTW": true, "LOTW_Date": "09/28/2026", "Comment": "RTTY",
      "Flag": "tn", "Band": 15.0, "Mode": "DIGITAL", "Continent_dx": "AF", "Continent_spotter": "EU"},
     {"Nr": 68003609, "Spotter": "IW1FRU", "Frequency": "3520.0", "DXCall": "OE8DDX", "Time": "05:51",
      "Date": "10/10/26", "Comment": "Youth WWA 2026 CW", "Flag": "at", "Band": 80.0, "Mode": "CW",
      "Continent_dx": "EU", "Continent_spotter": "EU", "DXLocator": "JN67PH"},
     {"Nr": 68003600, "Spotter": "PA3ABC", "Frequency": "7155.0", "DXCall": "EA8XYZ", "Time": "05:40",
      "Date": "10/10/26", "Comment": "", "Flag": "es", "Band": 40.0, "Continent_dx": "AF"},
     {"Nr": 1, "Spotter": "X", "Frequency": "abc", "DXCall": "BAD1"},
     {"Nr": 2, "Spotter": "X", "Frequency": "14000.0"},
     {"Nr": 3, "Spotter": 42, "Frequency": "14200.0", "DXCall": "OK1AB", "Time": "25:99"},
     "not an object"]
    """#

    func testParsesDXHeatResponse() throws {
        let spots = try DXHeatProvider.parse(Data(sample.utf8), now: now)
        XCTAssertEqual(spots.map(\.dxCall), ["8N0CC/P", "3V8LL", "OE8DDX", "EA8XYZ", "OK1AB"])

        let s = spots[0]
        XCTAssertEqual(s.frequency, 10_136_000)
        XCTAssertEqual(s.time, utc(5, 52))
        XCTAssertEqual(s.spotters, ["JF1KKV"])
        XCTAssertEqual(s.reportedMode, "DIGITAL")
        XCTAssertEqual(s.dxContinent, "AS")
        XCTAssertEqual(s.countryCode, "jp")
        XCTAssertEqual(s.locator, "PM95VQ")
        XCTAssertEqual(spots[1].frequency, 21_084_500)

        // Missing mode, empty comment, missing locator.
        XCTAssertNil(spots[3].reportedMode)
        XCTAssertNil(spots[3].locator)
        // A spotter of the wrong type is dropped; an invalid time falls back to now.
        XCTAssertEqual(spots[4].spotters, [])
        XCTAssertEqual(spots[4].time, now)
    }

    func testRejectsNonArrayResponse() {
        XCTAssertThrowsError(try DXHeatProvider.parse(Data("Bad Gateway".utf8))) {
            XCTAssertEqual($0 as? SpotProviderError, .badResponse)
        }
    }

    func testTimeResolvesToMostRecentMoment() {
        XCTAssertEqual(DXHeatProvider.resolveTime("05:59", now: now), utc(5, 59))
        // A few minutes ahead is clock skew, not yesterday.
        XCTAssertEqual(DXHeatProvider.resolveTime("06:03", now: now), utc(6, 3))
        // Later in the day than now: the spot was yesterday.
        XCTAssertEqual(DXHeatProvider.resolveTime("23:58", now: now), utc(23, 58, daysAgo: 1))
        XCTAssertNil(DXHeatProvider.resolveTime("6", now: now))
        XCTAssertNil(DXHeatProvider.resolveTime("24:00", now: now))
    }

    func testRequestURL() {
        let url = DXHeatProvider.url(limit: 50, continents: ["NA", "EU"])
        XCTAssertEqual(url.absoluteString, "https://dxheat.com/source/spots/?a=50&cdx=EU&cdx=NA&valid=1&spam=0")
        XCTAssertFalse(DXHeatProvider.url(limit: 10, continents: []).absoluteString.contains("cdx"))
    }

    func testModeMapping() {
        func mode(_ reported: String?, _ f: Double, _ comment: String = "") -> DemodMode {
            DXSpot.demodMode(reported: reported, frequency: f, comment: comment)
        }
        XCTAssertEqual(mode("CW", 3_520_000), .cw)
        XCTAssertEqual(mode("USB", 7_100_000), .usb)
        XCTAssertEqual(mode("lsb", 14_200_000), .lsb)
        XCTAssertEqual(mode("DIGITAL", 7_074_000), .usb, "digital modes use USB on every band")
        XCTAssertEqual(mode(nil, 7_155_000), .lsb)
        XCTAssertEqual(mode(nil, 14_250_000), .usb)
        XCTAssertEqual(mode(nil, 5_363_000), .usb, "60 m uses USB")
        XCTAssertEqual(mode(nil, 1_850_000), .lsb)
        XCTAssertEqual(mode(nil, 7_020_000, "tnx cw qso"), .cw)
        XCTAssertEqual(mode(nil, 7_020_000, "cwops"), .lsb, "only a whole word counts")
        XCTAssertEqual(mode(nil, 29_600_000, "FM simplex"), .nfm)
        XCTAssertEqual(mode(nil, 7_074_800), .usb, "FT8 segment")
        XCTAssertEqual(mode(nil, 7_074_800, "ssb net"), .lsb, "unless the comment says otherwise")
        XCTAssertEqual(mode(nil, 7_160_000, "js8 call"), .usb)
        XCTAssertEqual(mode("LSB", 7_074_500), .lsb, "a reported mode wins")
    }

    func testMergeKeepsNewestAndCollectsSpotters() {
        var a = spot("DL1AA", 14_025_000, utc(5, 40), spotter: "G4X", comment: "cq")
        a.merge(spot("dl1aa", 14_025_100, utc(5, 50), spotter: "PA1B", comment: ""))
        XCTAssertEqual(a.time, utc(5, 50))
        XCTAssertEqual(a.frequency, 14_025_100)
        XCTAssertEqual(a.spotters, ["PA1B", "G4X"])
        XCTAssertEqual(a.comment, "cq", "an empty comment does not replace one")

        a.merge(spot("DL1AA", 14_025_000, utc(5, 30), spotter: "K1Z", comment: "old"))
        XCTAssertEqual(a.time, utc(5, 50), "an older report does not move the spot back")
        XCTAssertEqual(a.comment, "cq")
        XCTAssertEqual(a.spotters, ["PA1B", "G4X", "K1Z"])
    }

    func testDuplicateKey() {
        XCTAssertEqual(spot("dl1aa", 14_025_400, now).id, spot("DL1AA", 14_024_600, now).id)
        XCTAssertNotEqual(spot("DL1AA", 14_025_000, now).id, spot("DL1AA", 14_026_000, now).id)
    }

    /// Fetches from the real DXHeat server; only runs with `KYMARA_NETWORK_TESTS=1`.
    func testLiveDXHeat() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KYMARA_NETWORK_TESTS"] == "1",
                          "set KYMARA_NETWORK_TESTS=1 to fetch from dxheat.com")
        let spots = try await DXHeatProvider().fetchSpots(limit: 20, continents: ["EU"])
        XCTAssertFalse(spots.isEmpty)
        XCTAssertTrue(spots.allSatisfy { $0.dxContinent == "EU" && $0.frequency > 100_000 })
        XCTAssertTrue(spots.allSatisfy { abs($0.time.timeIntervalSinceNow) < 6 * 3_600 })
    }

    // MARK: Store

    @MainActor
    func testStoreMergesAndAgesOut() async {
        var clock = now
        let provider = FakeProvider()
        let store = DXClusterStore(provider: provider, now: { clock })
        store.maxAge = 30 * 60

        provider.result = .success([
            spot("DL1AA", 14_025_000, utc(5, 50), spotter: "A"),
            spot("DL1AA", 14_025_200, utc(5, 52), spotter: "B"),
            spot("JA1XX", 21_074_000, utc(5, 20)),   // already too old
            spot("VK2YY", 7_150_000, utc(5, 45)),
        ])
        await store.refresh()
        XCTAssertEqual(store.spots.map(\.dxCall), ["DL1AA", "VK2YY"])
        XCTAssertEqual(store.spots[0].spotters, ["B", "A"])
        XCTAssertEqual(store.lastUpdate, now)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.spots(in: 7_000_000...7_300_000).map(\.dxCall), ["VK2YY"])

        clock = now.addingTimeInterval(20 * 60)   // 06:20: VK2YY (05:45) has expired
        provider.result = .success([spot("OH0Z", 18_080_000, utc(6, 19))])
        await store.refresh()
        XCTAssertEqual(store.spots.map(\.dxCall), ["OH0Z", "DL1AA"])
    }

    @MainActor
    func testStoreKeepsSpotsAndBacksOffOnFailure() async {
        let provider = FakeProvider()
        let store = DXClusterStore(provider: provider, now: { self.now })
        store.refreshInterval = 60
        provider.result = .success([spot("DL1AA", 14_025_000, utc(5, 55))])
        await store.refresh()
        XCTAssertEqual(store.nextDelay, 60)

        provider.result = .failure(SpotProviderError.http(502))
        await store.refresh()
        XCTAssertEqual(store.spots.count, 1, "a failed poll keeps the spots it had")
        XCTAssertEqual(store.lastError, SpotProviderError.http(502).errorDescription)
        XCTAssertEqual(store.nextDelay, 120)
        await store.refresh()
        XCTAssertEqual(store.nextDelay, 240)
        for _ in 0..<10 { await store.refresh() }
        XCTAssertEqual(store.nextDelay, DXClusterStore.maximumBackoff)

        provider.result = .success([])
        await store.refresh()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.nextDelay, 60)
    }

    func testCategory() {
        var s = spot("DL1AA", 14_200_000, now)
        s.reportedMode = "DIGITAL"
        XCTAssertEqual(s.category, .digital)
        s.reportedMode = "CW"
        XCTAssertEqual(s.category, .cw)
        s.reportedMode = nil
        XCTAssertEqual(s.category, .phone)
        s.comment = "cw 599"
        XCTAssertEqual(s.category, .cw)
        s.comment = ""
        s.frequency = 14_075_200
        XCTAssertEqual(s.category, .digital, "FT8 segment without a reported mode")
    }

    @MainActor
    func testListFilters() async {
        let provider = FakeProvider()
        let store = DXClusterStore(provider: provider, now: { self.now })
        var digital = spot("JA1XX", 14_074_000, utc(5, 58))
        digital.reportedMode = "DIGITAL"
        var cw = spot("OH0Z", 14_025_000, utc(5, 57), spotter: "PA3ABC", comment: "up 1")
        cw.reportedMode = "CW"
        provider.result = .success([digital, cw, spot("VK2YY", 7_150_000, utc(5, 56))])
        await store.refresh()

        let tuner = 13_000_000.0...15_000_000.0, view = 7_000_000.0...7_200_000.0
        func calls(_ search: String = "") -> [String] {
            store.filteredSpots(search: search, tuner: tuner, view: view).map(\.dxCall)
        }
        XCTAssertEqual(calls(), ["JA1XX", "OH0Z", "VK2YY"])
        XCTAssertEqual(calls("oh0"), ["OH0Z"])
        XCTAssertEqual(calls("pa3"), ["OH0Z"], "search matches spotters")
        XCTAssertEqual(calls("UP 1"), ["OH0Z"], "search matches comments")
        XCTAssertEqual(calls("7.150"), ["VK2YY"], "search matches frequencies")

        store.scope = .tuner
        XCTAssertEqual(calls(), ["JA1XX", "OH0Z"])
        store.scope = .view
        XCTAssertEqual(calls(), ["VK2YY"])
        store.scope = .all
        store.categories = [.cw, .digital]
        XCTAssertEqual(calls(), ["JA1XX", "OH0Z"])
    }

    @MainActor
    func testRefreshIntervalHasAMinimum() {
        let store = DXClusterStore(provider: FakeProvider())
        store.refreshInterval = 5
        XCTAssertEqual(store.nextDelay, DXClusterStore.minimumInterval)
    }

    @MainActor
    func testEnablingPollsAndDisablingClears() async throws {
        let provider = FakeProvider()
        provider.result = .success([spot("DL1AA", 14_025_000, Date())])
        let store = DXClusterStore(provider: provider)
        store.isEnabled = true
        for _ in 0..<100 where store.spots.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.spots.count, 1)
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(provider.lastContinents, [])

        store.isEnabled = false
        XCTAssertTrue(store.spots.isEmpty)
        XCTAssertNil(store.lastUpdate)
    }

    private func spot(_ call: String, _ f: Double, _ t: Date, spotter: String = "X", comment: String = "") -> DXSpot {
        DXSpot(dxCall: call, frequency: f, time: t, spotters: [spotter], comment: comment, reportedMode: nil,
               dxContinent: "EU", spotterContinent: "EU", countryCode: "", locator: nil)
    }
}

private final class FakeProvider: SpotProvider, @unchecked Sendable {
    let name = "Fake"
    var result: Result<[DXSpot], Error> = .success([])
    var calls = 0
    var lastContinents: Set<String>?

    func fetchSpots(limit: Int, continents: Set<String>) async throws -> [DXSpot] {
        calls += 1
        lastContinents = continents
        return try result.get()
    }
}
