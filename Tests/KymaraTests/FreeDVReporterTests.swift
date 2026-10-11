import XCTest
@testable import Kymara

@MainActor
private final class FakeTransport: ReporterTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onClose: ((String?) -> Void)?
    var emitted: [(String, [String: Any])] = []
    var closed = false

    func emit(_ event: String, _ data: [String: Any]) { emitted.append((event, data)) }
    func close() { closed = true }
    var names: [String] { emitted.map(\.0) }
}

@MainActor
final class FreeDVReporterTests: XCTestCase {
    private var time = Date(timeIntervalSince1970: 1_791_612_000)
    private var transports: [FakeTransport] = []
    private var auths: [[String: Any]] = []

    private func makeReporter() -> FreeDVReporter {
        let r = FreeDVReporter(version: "1.2.3", now: { [unowned self] in time }) { [unowned self] _, auth in
            auths.append(auth)
            let t = FakeTransport()
            transports.append(t)
            return t
        }
        r.callsign = "pa0abc"
        r.locator = "jo22AB"
        r.message = " Listening on an RSP1 "
        r.isEnabled = true
        return r
    }

    private func advance(_ seconds: TimeInterval) { time = time.addingTimeInterval(seconds) }

    func testPacketParsing() {
        XCTAssertEqual(SocketIOPacket.parse(#"0{"sid":"x","pingInterval":5000}"#), .open)
        XCTAssertEqual(SocketIOPacket.parse("2"), .ping)
        XCTAssertEqual(SocketIOPacket.parse(#"40{"sid":"abc"}"#), .connected)
        XCTAssertEqual(SocketIOPacket.parse(#"44{"message":"Not authorized"}"#), .refused("Not authorized"))
        XCTAssertEqual(SocketIOPacket.parse(#"42["connection_successful"]"#), .event("connection_successful", [:]))
        XCTAssertEqual(SocketIOPacket.parse(#"42["freq_change",{"callsign":"K1AB","freq":7177000}]"#),
                       .event("freq_change", ["callsign": "K1AB", "freq": 7_177_000]))
        XCTAssertEqual(SocketIOPacket.parse("42not json"), .other)
        XCTAssertEqual(SocketIOPacket.parse("3"), .other)
    }

    func testPacketEncoding() {
        XCTAssertEqual(SocketIOPacket.event("freq_change", ["freq": 7_177_000]), #"42["freq_change",{"freq":7177000}]"#)
        XCTAssertEqual(SocketIOPacket.event("hide_self", nil), #"42["hide_self"]"#)
        XCTAssertEqual(SocketIOPacket.connect(auth: ["role": "view", "protocol_version": 2]),
                       #"40{"protocol_version":2,"role":"view"}"#)
    }

    func testValidation() {
        XCTAssertEqual(FreeDVReporter.normalizedCallsign(" pa0abc/p "), "PA0ABC/P")
        XCTAssertNil(FreeDVReporter.normalizedCallsign("PA"))
        XCTAssertNil(FreeDVReporter.normalizedCallsign("ABCDEF"), "needs a digit")
        XCTAssertNil(FreeDVReporter.normalizedCallsign("PA0 ABC"))
        XCTAssertEqual(FreeDVReporter.normalizedLocator("jo22"), "JO22")
        XCTAssertEqual(FreeDVReporter.normalizedLocator("jo22AB"), "JO22ab")
        XCTAssertNil(FreeDVReporter.normalizedLocator("JZ22"), "fields run A–R")
        XCTAssertNil(FreeDVReporter.normalizedLocator("JO22az"), "subsquares run a–x")
        XCTAssertNil(FreeDVReporter.normalizedLocator("JO2"))
    }

    func testConnectsOnlyWhileActiveAndConfigured() {
        let r = makeReporter()
        advance(2)
        r.update(active: false, frequency: 7_177_000)
        XCTAssertTrue(transports.isEmpty)

        r.update(active: true, frequency: 7_177_000)
        XCTAssertEqual(transports.count, 1)
        XCTAssertEqual(r.state, .connecting)
        let auth = auths[0]
        XCTAssertEqual(auth["role"] as? String, "report")
        XCTAssertEqual(auth["callsign"] as? String, "PA0ABC")
        XCTAssertEqual(auth["grid_square"] as? String, "JO22ab")
        XCTAssertEqual(auth["version"] as? String, "Kymara 1.2.3")
        XCTAssertEqual(auth["rx_only"] as? Bool, true)
        XCTAssertEqual(auth["protocol_version"] as? Int, 2)

        r.update(active: false, frequency: 7_177_000)
        XCTAssertTrue(transports[0].closed)
        XCTAssertEqual(r.state, .idle)

        r.locator = "nonsense"
        advance(2)
        r.update(active: true, frequency: 7_177_000)
        XCTAssertEqual(transports.count, 1, "no connection without a valid locator")
    }

    func testSendsStationInfoOnceRegisteredAndSettledFrequencyChanges() {
        let r = makeReporter()
        advance(2)
        r.update(active: true, frequency: 7_177_000)
        let t = transports[0]
        r.heard(callsign: "K1AB", snr: 5)
        XCTAssertTrue(t.emitted.isEmpty, "nothing is sent before connection_successful")

        t.onEvent?("connection_successful", [:])
        XCTAssertEqual(r.state, .connected)
        XCTAssertEqual(t.names, ["freq_change", "tx_report", "message_update"])
        XCTAssertEqual(t.emitted[0].1["freq"] as? Int, 7_177_000)
        XCTAssertEqual(t.emitted[1].1["mode"] as? String, "RADEV1")
        XCTAssertEqual(t.emitted[1].1["transmitting"] as? Bool, false)
        XCTAssertEqual(t.emitted[2].1["message"] as? String, "Listening on an RSP1")

        // Dragging the VFO: only the settled frequency is sent.
        for f in stride(from: 7_177_100.0, through: 7_178_000, by: 100) {
            advance(0.1)
            r.update(active: true, frequency: f)
        }
        XCTAssertEqual(t.names.count, 3)
        advance(1)
        r.update(active: true, frequency: 7_178_000)
        XCTAssertEqual(t.names.last, "freq_change")
        XCTAssertEqual(t.emitted.last?.1["freq"] as? Int, 7_178_000)
        XCTAssertEqual(t.names.count, 4)
    }

    func testReceiveReports() {
        let r = makeReporter()
        advance(2)
        r.update(active: true, frequency: 7_177_000)
        let t = transports[0]
        t.onEvent?("connection_successful", [:])
        t.emitted = []

        r.heard(callsign: nil, snr: 3.6)
        r.heard(callsign: nil, snr: 4)
        XCTAssertEqual(t.emitted.count, 1, "sync reports are throttled")
        XCTAssertEqual(t.emitted[0].1["callsign"] as? String, "")
        XCTAssertEqual(t.emitted[0].1["snr"] as? Int, 4)

        advance(3)
        r.heard(callsign: "K1AB", snr: 7.2)
        XCTAssertEqual(t.emitted.count, 2, "a decoded callsign is always reported")
        XCTAssertEqual(t.emitted[1].0, "rx_report")
        XCTAssertEqual(t.emitted[1].1["callsign"] as? String, "K1AB")
        XCTAssertEqual(t.emitted[1].1["mode"] as? String, "RADEV1")
        XCTAssertEqual(t.emitted[1].1["snr"] as? Int, 7)

        advance(FreeDVReporter.syncReportInterval)
        r.heard(callsign: nil, snr: 2)
        XCTAssertEqual(t.emitted.count, 3)
    }

    func testMessageChangeIsSentWithoutReconnecting() {
        let r = makeReporter()
        advance(2)
        r.update(active: true, frequency: 7_177_000)
        let t = transports[0]
        t.onEvent?("connection_successful", [:])
        t.emitted = []

        r.message = "QRV"
        r.update(active: true, frequency: 7_177_000)
        XCTAssertTrue(t.emitted.isEmpty, "waits until typing has settled")
        advance(1)
        r.update(active: true, frequency: 7_177_000)
        XCTAssertEqual(t.names, ["message_update"])
        XCTAssertEqual(t.emitted[0].1["message"] as? String, "QRV")
        XCTAssertEqual(transports.count, 1)
        XCTAssertFalse(t.closed)
    }

    func testRetriesAfterFailureWithBackoff() {
        let r = makeReporter()
        advance(2)
        r.update(active: true, frequency: 7_177_000)
        transports[0].onClose?("Network down")
        XCTAssertEqual(r.state, .failed("Network down"))
        XCTAssertEqual(r.retryDelay, 5)
        r.update(active: true, frequency: 7_177_000)
        XCTAssertEqual(transports.count, 1, "waits before retrying")
    }

    func testSettingsChangeReconnects() {
        let r = makeReporter()
        advance(2)
        r.update(active: true, frequency: 7_177_000)
        r.callsign = "PA0XYZ"
        r.update(active: true, frequency: 7_177_000)
        XCTAssertEqual(transports.count, 1, "waits until typing has settled")
        advance(1)
        r.update(active: true, frequency: 7_177_000)
        XCTAssertTrue(transports[0].closed)
        XCTAssertEqual(transports.count, 2)
        XCTAssertEqual(auths[1]["callsign"] as? String, "PA0XYZ")
    }

    func testSettingsPersistence() throws {
        let defaults = UserDefaults(suiteName: "KymaraTests.FreeDVReporter")!
        defaults.removePersistentDomain(forName: "KymaraTests.FreeDVReporter")
        let store = SettingsStore(defaults: defaults)
        let r = FreeDVReporter(persistence: store)
        r.callsign = "PA0ABC"
        r.locator = "JO22"
        r.message = "QRV"
        r.isEnabled = true
        XCTAssertEqual(FreeDVReporter(persistence: store).settings,
                       FreeDVReporterSettings(enabled: true, callsign: "PA0ABC", locator: "JO22", message: "QRV"))

        // A blob with a missing and a mistyped field keeps the rest.
        defaults.set(Data(#"{"callsign":"K1AB","enabled":"yes"}"#.utf8), forKey: SettingsStore.freedvReporterKey)
        XCTAssertEqual(store.loadFreeDVReporter(), FreeDVReporterSettings(enabled: false, callsign: "K1AB", locator: ""))
    }

    /// Connects to the real server as a viewer (which doesn't add a station to the map); only runs with
    /// `KYMARA_NETWORK_TESTS=1`.
    func testLiveServerHandshake() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KYMARA_NETWORK_TESTS"] == "1",
                          "set KYMARA_NETWORK_TESTS=1 to connect to qso.freedv.org")
        let connected = expectation(description: "connection_successful")
        let client = SocketIOClient(host: FreeDVReporter.host,
                                    auth: ["role": "view", "protocol_version": FreeDVReporter.protocolVersion])
        client.onEvent = { name, _ in if name == "connection_successful" { connected.fulfill() } }
        client.onClose = { message in XCTFail("closed: \(message ?? "")") }
        await fulfillment(of: [connected], timeout: 15)
        client.onClose = nil
        client.close()
    }
}
