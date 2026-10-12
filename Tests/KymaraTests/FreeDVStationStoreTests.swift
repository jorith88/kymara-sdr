import XCTest
@testable import Kymara

@MainActor
private final class FakeTransport: ReporterTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onClose: ((String?) -> Void)?
    var closed = false
    func emit(_ event: String, _ data: [String: Any]) {}
    func close() { closed = true }
}

@MainActor
final class FreeDVStationStoreTests: XCTestCase {
    /// 2026-10-11 06:00:00 UTC.
    private var time = Date(timeIntervalSince1970: 1_791_698_400)
    private var transports: [FakeTransport] = []
    private var auths: [[String: Any]] = []

    private func makeStore() -> FreeDVStationStore {
        FreeDVStationStore(now: { [unowned self] in time }) { [unowned self] _, auth in
            auths.append(auth)
            let t = FakeTransport()
            transports.append(t)
            return t
        }
    }

    /// Events as the server sends them (from a real `bulk_update`), decoded the way the client does.
    private func events(_ json: String) -> [(String, [String: Any])] {
        guard case .bulk(let events) = SocketIOPacket.parse("42" + json) else {
            XCTFail("not a bulk update")
            return []
        }
        return events.map { ($0.name, $0.data) }
    }

    private let bulk = #"""
    ["bulk_update",[
     ["chat_message",{"sentDate":"2026-04-25T21:28:33.116780+00:00","username":"N6UG","content":"Hi"}],
     ["new_connection",{"sid":"A","last_update":"2026-10-09T17:45:22.482298+00:00","callsign":"K0RO","grid_square":"EM51ij","version":"FreeDV 2.4.0","rx_only":false,"os":"windows","connect_time":"2026-10-09T14:12:14.897864+00:00"}],
     ["freq_change",{"sid":"A","last_update":"2026-10-09T17:45:22.482298+00:00","callsign":"K0RO","grid_square":"EM51ij","freq":14236000}],
     ["tx_report",{"sid":"A","last_update":"2026-10-09T17:45:22.482298+00:00","callsign":"K0RO","grid_square":"EM51ij","mode":"RADEV1","transmitting":false,"last_tx":null}],
     ["message_update",{"sid":"A","last_update":"2026-10-09T17:45:22.482298+00:00","message":"Ralph, Petal, MS"}],
     ["new_connection",{"sid":"B","last_update":"2026-10-11T05:50:00.000000+00:00","callsign":"ZL2IT","grid_square":"RE78","version":"FreeDV 2.4.0","rx_only":false,"os":"macos","connect_time":"2026-10-11T05:00:00.000000+00:00"}],
     ["freq_change",{"sid":"B","last_update":"2026-10-11T05:50:00.000000+00:00","callsign":"ZL2IT","grid_square":"RE78","freq":7083000}],
     ["tx_report",{"sid":"B","last_update":"2026-10-11T05:58:00.000000+00:00","callsign":"ZL2IT","grid_square":"RE78","mode":"RADEV1","transmitting":false,"last_tx":"2026-10-11T05:58:47.683594+00:00"}],
     ["new_connection",{"sid":"C","last_update":"2026-10-11T05:00:00.000000+00:00","callsign":"","grid_square":"","version":"freedv-reporter","rx_only":true,"os":"","connect_time":"2026-10-11T05:00:00.000000+00:00"}],
     ["new_connection",{"sid":"D","last_update":"2026-10-11T05:00:00.000000+00:00","callsign":"JG2FFB","grid_square":"PM85","version":"FreeDV 2.4.0","rx_only":false,"os":"linux","connect_time":"2026-10-11T05:00:00.000000+00:00"}],
     ["freq_change",{"sid":"D","last_update":"2026-10-11T05:00:00.000000+00:00","callsign":"JG2FFB","grid_square":"PM85","freq":7192000}],
     ["tx_report",{"sid":"D","last_update":"2026-10-11T05:00:00.000000+00:00","callsign":"JG2FFB","grid_square":"PM85","mode":"RADEV1","transmitting":false,"last_tx":"2026-10-11T00:42:09.171894+00:00"}]
    ]]
    """#

    private func loadedStore() -> FreeDVStationStore {
        let store = makeStore()
        for (name, data) in events(bulk) { store.apply(name, data) }
        return store
    }

    func testParsesDates() {
        XCTAssertEqual(FreeDVStationStore.parseDate("2026-10-11T05:58:47.683594+00:00")?.timeIntervalSince1970 ?? 0,
                       1_791_698_327.683, accuracy: 0.001)
        XCTAssertEqual(FreeDVStationStore.parseDate("2026-10-11T06:00:00+00:00"), time)
        XCTAssertEqual(FreeDVStationStore.parseDate("2026-10-11T06:00:00.5Z")?.timeIntervalSince(time), 0.5)
        XCTAssertNil(FreeDVStationStore.parseDate("yesterday"))
    }

    func testAppliesBulkUpdate() throws {
        let store = loadedStore()
        XCTAssertEqual(store.stations.count, 4, "the anonymous viewer is kept, but not listed")
        XCTAssertEqual(Set(store.listedStations.map(\.callsign)), ["K0RO", "ZL2IT", "JG2FFB"])

        let k0ro = try XCTUnwrap(store.stations["A"])
        XCTAssertEqual(k0ro.locator, "EM51ij")
        XCTAssertEqual(k0ro.frequency, 14_236_000)
        XCTAssertEqual(k0ro.mode, "RADEV1")
        XCTAssertFalse(k0ro.transmitting)
        XCTAssertNil(k0ro.lastTransmission)
        XCTAssertEqual(k0ro.message, "Ralph, Petal, MS")
        XCTAssertEqual(k0ro.version, "FreeDV 2.4.0")
    }

    func testLiveUpdates() throws {
        let store = loadedStore()
        store.apply("tx_report", ["sid": "A", "callsign": "K0RO", "grid_square": "EM51ij", "mode": "RADEV1",
                                  "transmitting": true, "last_tx": NSNull()])
        XCTAssertTrue(try XCTUnwrap(store.stations["A"]).transmitting)
        XCTAssertEqual(store.stations["A"]?.lastTransmission, time, "a transmission without last_tx starts now")

        store.apply("rx_report", ["sid": "B", "last_update": "2026-10-11T06:00:00.000000+00:00",
                                  "receiver_callsign": "ZL2IT", "receiver_grid_square": "RE78",
                                  "callsign": "K0RO", "snr": 4.5, "mode": "RADEV1"])
        XCTAssertEqual(store.stations["B"]?.heard, .init(callsign: "K0RO", snr: 4.5, time: time))

        store.apply("remove_connection", ["sid": "A", "callsign": "K0RO"])
        XCTAssertNil(store.stations["A"])

        // An update for a station the list missed adds it.
        store.apply("freq_change", ["sid": "E", "callsign": "PA0ABC", "grid_square": "JO22", "freq": 3_625_000])
        XCTAssertEqual(store.stations["E"]?.callsign, "PA0ABC")
        XCTAssertEqual(store.stations["E"]?.frequency, 3_625_000)
    }

    func testDuplicateSessionsAreListedOnce() {
        let store = loadedStore()
        store.apply("new_connection", ["sid": "A2", "callsign": "k0ro", "grid_square": "EM51ij", "version": "FreeDV 2.4.0",
                                       "rx_only": false])
        store.apply("freq_change", ["sid": "A2", "callsign": "k0ro", "grid_square": "EM51ij", "freq": 14_236_000])
        store.apply("tx_report", ["sid": "A2", "mode": "RADEV1", "transmitting": false,
                                  "last_tx": "2026-10-11T05:00:00.000000+00:00"])
        let k0ro = store.listedStations.filter { $0.callsign.uppercased() == "K0RO" }
        XCTAssertEqual(k0ro.map(\.id), ["A2"], "the session that transmitted wins")

        // On another frequency it is another entry.
        store.apply("freq_change", ["sid": "A2", "callsign": "k0ro", "grid_square": "EM51ij", "freq": 7_177_000])
        XCTAssertEqual(store.listedStations.filter { $0.callsign.uppercased() == "K0RO" }.count, 2)
    }

    func testOwnCallsignIsNotListed() {
        let store = loadedStore()
        store.ownCallsign = " zl2it "
        XCTAssertEqual(Set(store.listedStations.map(\.callsign)), ["K0RO", "JG2FFB"])
        store.ownCallsign = ""
        XCTAssertTrue(store.listedStations.contains { $0.callsign == "ZL2IT" })
    }

    func testBogusFrequencyIsIgnored() {
        let store = loadedStore()
        for freq in [1e300, Double.infinity, -5.0] {
            store.apply("freq_change", ["sid": "X", "callsign": "PA0BAD", "freq": freq])
            XCTAssertEqual(store.stations["X"]?.frequency, 0)
            XCTAssertFalse(store.listedStations.contains { $0.callsign == "PA0BAD" })
        }
    }

    func testBandScopeAndOrder() {
        let store = loadedStore()
        XCTAssertEqual(store.stations(scope: .band, vfo: 7_100_000).map(\.callsign), ["ZL2IT", "JG2FFB"],
                       "most recent transmission first")
        XCTAssertEqual(store.stations(scope: .band, vfo: 14_236_000).map(\.callsign), ["K0RO"])
        XCTAssertTrue(store.stations(scope: .band, vfo: 100_000_000).isEmpty, "not on an amateur band")
        XCTAssertEqual(store.stations(scope: .all, vfo: 100_000_000).count, 3)

        store.apply("tx_report", ["sid": "D", "mode": "RADEV1", "transmitting": true,
                                  "last_tx": "2026-10-11T06:00:00.000000+00:00"])
        XCTAssertEqual(store.stations(scope: .band, vfo: 7_100_000).first?.callsign, "JG2FFB", "transmitting first")
    }

    func testTransmitterLabels() {
        let store = loadedStore()
        // ZL2IT transmitted 1 min ago, JG2FFB 5 h ago, K0RO never.
        XCTAssertEqual(store.transmitters(in: 7_000_000...7_300_000).map(\.callsign), ["ZL2IT"])
        XCTAssertTrue(store.transmitters(in: 14_000_000...14_350_000).isEmpty)
        time = time.addingTimeInterval(FreeDVStationStore.transmitterWindow)
        XCTAssertTrue(store.transmitters(in: 7_000_000...7_300_000).isEmpty)
    }

    func testConnectsAsViewerWhileEnabledAndVisible() {
        let store = makeStore()
        XCTAssertTrue(transports.isEmpty)
        store.isEnabled = true
        XCTAssertEqual(transports.count, 1)
        XCTAssertEqual(auths[0]["role"] as? String, "view")
        XCTAssertNil(auths[0]["callsign"], "a viewer doesn't put a station on the map")
        XCTAssertEqual(store.state, .connecting)

        transports[0].onEvent?("connection_successful", [:])
        XCTAssertEqual(store.state, .connected)
        for (name, data) in events(bulk) { transports[0].onEvent?(name, data) }
        XCTAssertEqual(store.listedStations.count, 3)

        store.isPaused = true
        XCTAssertTrue(transports[0].closed)
        XCTAssertEqual(store.listedStations.count, 3, "the list stays while paused")
        store.isPaused = false
        XCTAssertEqual(transports.count, 2)
        XCTAssertTrue(store.listedStations.isEmpty, "the server sends the list again")

        store.isEnabled = false
        XCTAssertTrue(transports[1].closed)
        XCTAssertEqual(store.state, .idle)
    }

    func testAmateurBands() {
        XCTAssertEqual(AmateurBand.containing(7_177_000)?.name, "40 m")
        XCTAssertEqual(AmateurBand.containing(14_236_000)?.name, "20 m")
        XCTAssertNil(AmateurBand.containing(9_000_000))
        XCTAssertEqual(AmateurBand.above(7_100_000)?.name, "30 m", "skips the band it is in")
        XCTAssertEqual(AmateurBand.below(7_100_000)?.name, "60 m")
        XCTAssertEqual(AmateurBand.above(9_000_000)?.name, "30 m")
        XCTAssertEqual(AmateurBand.below(9_000_000)?.name, "40 m")
        XCTAssertNil(AmateurBand.above(433_000_000))
        XCTAssertNil(AmateurBand.below(1_900_000))
        for band in AmateurBand.all { XCTAssertTrue(band.range.contains(band.home), band.name) }
    }

    func testSettingsPersistence() {
        let defaults = UserDefaults(suiteName: "KymaraTests.FreeDVStations")!
        defaults.removePersistentDomain(forName: "KymaraTests.FreeDVStations")
        let store = SettingsStore(defaults: defaults)
        let s = FreeDVStationStore(persistence: store, makeTransport: { _, _ in FakeTransport() })
        s.scope = .all
        s.isEnabled = true
        XCTAssertEqual(store.loadFreeDVStations(), FreeDVStationSettings(enabled: true, scope: .all))
        defaults.set(Data(#"{"scope":"Nonsense","enabled":true}"#.utf8), forKey: SettingsStore.freedvStationsKey)
        XCTAssertEqual(store.loadFreeDVStations(), FreeDVStationSettings(enabled: true, scope: .band))
    }
}
