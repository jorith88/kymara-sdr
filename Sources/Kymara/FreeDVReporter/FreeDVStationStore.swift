import Foundation
import Observation

/// A station connected to FreeDV Reporter, as the server describes it.
struct FreeDVStation: Identifiable, Equatable, Sendable {
    /// The server's session id; one callsign can be connected more than once.
    let id: String
    var callsign: String
    var locator: String
    var version = ""
    var rxOnly = false
    /// Dial frequency in Hz; 0 when unknown.
    var frequency: Double = 0
    var mode = ""
    var transmitting = false
    var lastTransmission: Date?
    var message = ""
    /// The station this one last decoded, with the SNR it reported.
    var heard: Heard?

    struct Heard: Equatable, Sendable {
        var callsign: String
        var snr: Double
        var time: Date
    }

    /// Transmitting, or transmitted within `window`: a station worth a label on the spectrum.
    func isRecentTransmitter(now: Date, window: TimeInterval = FreeDVStationStore.transmitterWindow) -> Bool {
        transmitting || lastTransmission.map { now.timeIntervalSince($0) < window } ?? false
    }
}

/// Which stations the FreeDV list shows.
enum FreeDVStationScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case band = "Current Band"
    case all = "All Bands"
    var id: String { rawValue }
}

/// The live station list from FreeDV Reporter (qso.freedv.org), received as a viewer: our own station doesn't
/// appear on the map because of it. Connected while enabled and a Kymara window is visible.
@MainActor
@Observable
final class FreeDVStationStore {
    /// Stations that transmitted this recently get a label on the spectrum.
    nonisolated static let transmitterWindow: TimeInterval = 15 * 60
    static let maximumBackoff: TimeInterval = 300

    enum State: Equatable {
        case idle, connecting, connected
        case failed(String)
    }

    /// By session id.
    private(set) var stations: [String: FreeDVStation] = [:]
    private(set) var state: State = .idle

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            save()
            reconcile()
        }
    }
    var scope: FreeDVStationScope = .band { didSet { save() } }
    /// Set while no Kymara window is visible: the connection closes, the list stays until it reopens.
    var isPaused = false { didSet { if isPaused != oldValue { reconcile() } } }
    /// Our own reporting callsign (from the FreeDV Reporter settings); its sessions are not listed.
    var ownCallsign = ""

    @ObservationIgnored private let makeTransport: @MainActor (String, [String: Any]) -> ReporterTransport
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let persistence: SettingsStore?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var transport: ReporterTransport?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private(set) var consecutiveFailures = 0

    init(persistence: SettingsStore? = nil, now: @escaping () -> Date = Date.init,
         makeTransport: @escaping @MainActor (String, [String: Any]) -> ReporterTransport = { SocketIOClient(host: $0, auth: $1) }) {
        self.persistence = persistence
        self.now = now
        self.makeTransport = makeTransport
        if let saved = persistence?.loadFreeDVStations() {
            loading = true
            scope = saved.scope
            isEnabled = saved.enabled
            loading = false
        }
    }

    var settings: FreeDVStationSettings { FreeDVStationSettings(enabled: isEnabled, scope: scope) }

    private func save() {
        guard !loading else { return }
        persistence?.saveFreeDVStations(settings)
    }

    // MARK: Queries

    /// Stations with a callsign and a frequency (the server also lists anonymous viewers), except our own.
    /// A station connected more than once on the same frequency is listed once, by its most active session.
    var listedStations: [FreeDVStation] {
        let own = ownCallsign.trimmingCharacters(in: .whitespaces).uppercased()
        var best: [String: FreeDVStation] = [:]
        for s in stations.values where !s.callsign.isEmpty && s.frequency > 0 && s.callsign.uppercased() != own {
            let key = "\(s.callsign.uppercased())@\(Int(s.frequency))"
            if let other = best[key], !Self.isMoreActive(s, than: other) { continue }
            best[key] = s
        }
        return Array(best.values)
    }

    /// Transmitting beats not, then the more recent transmission, then a message; the session id keeps it stable.
    private static func isMoreActive(_ a: FreeDVStation, than b: FreeDVStation) -> Bool {
        if a.transmitting != b.transmitting { return a.transmitting }
        let ta = a.lastTransmission ?? .distantPast, tb = b.lastTransmission ?? .distantPast
        if ta != tb { return ta > tb }
        if a.message.isEmpty != b.message.isEmpty { return !a.message.isEmpty }
        return a.id < b.id
    }

    /// Listed stations in the scope, for the list: transmitting first, then by most recent transmission,
    /// then by callsign. `vfo` decides the current band.
    func stations(scope: FreeDVStationScope, vfo: Double) -> [FreeDVStation] {
        let band = AmateurBand.containing(vfo)
        let shown = listedStations.filter { station in
            switch scope {
            case .all: return true
            case .band: return band.map { $0.range.contains(station.frequency) } ?? false
            }
        }
        return shown.sorted { a, b in
            if a.transmitting != b.transmitting { return a.transmitting }
            let ta = a.lastTransmission ?? .distantPast, tb = b.lastTransmission ?? .distantPast
            if ta != tb { return ta > tb }
            return a.callsign.uppercased() < b.callsign.uppercased()
        }
    }

    /// Stations between two frequencies that are transmitting or did so recently, for the spectrum labels.
    func transmitters(in range: ClosedRange<Double>) -> [FreeDVStation] {
        let t = now()
        return listedStations
            .filter { range.contains($0.frequency) && $0.isRecentTransmitter(now: t) }
            .sorted { ($0.transmitting ? 1 : 0, $0.lastTransmission ?? .distantPast) > ($1.transmitting ? 1 : 0, $1.lastTransmission ?? .distantPast) }
    }

    // MARK: Events

    /// Applies one FreeDV Reporter event to the station list.
    func apply(_ name: String, _ data: [String: Any]) {
        guard let sid = data["sid"] as? String else { return }
        switch name {
        case "new_connection":
            var s = stations[sid] ?? FreeDVStation(id: sid, callsign: "", locator: "")
            s.callsign = data["callsign"] as? String ?? s.callsign
            s.locator = data["grid_square"] as? String ?? s.locator
            s.version = data["version"] as? String ?? s.version
            s.rxOnly = data["rx_only"] as? Bool ?? s.rxOnly
            stations[sid] = s
        case "remove_connection":
            stations[sid] = nil
        case "freq_change":
            update(sid, data) { s in
                // Clients report whatever they like; a huge or non-finite value would trap in `Int(_:)`.
                if let f = Self.number(data["freq"]) { s.frequency = f.isFinite && f > 0 && f < 1e12 ? f : 0 }
            }
        case "tx_report":
            update(sid, data) { s in
                if let m = data["mode"] as? String { s.mode = m }
                if let tx = data["transmitting"] as? Bool { s.transmitting = tx }
                if let t = (data["last_tx"] as? String).flatMap(Self.parseDate) {
                    s.lastTransmission = t
                } else if s.transmitting {
                    s.lastTransmission = now()
                }
            }
        case "message_update":
            update(sid, data) { s in
                if let m = data["message"] as? String { s.message = m }
            }
        case "rx_report":
            update(sid, data) { s in
                guard let call = data["callsign"] as? String, let snr = Self.number(data["snr"]) else { return }
                let time = (data["last_update"] as? String).flatMap(Self.parseDate) ?? now()
                s.heard = .init(callsign: call, snr: snr, time: time)
            }
        default:
            break
        }
    }

    /// Updates a known station; a station first seen in an update (it connected before we did and the
    /// list missed it) is added with the callsign and locator the update carries.
    private func update(_ sid: String, _ data: [String: Any], _ change: (inout FreeDVStation) -> Void) {
        var s = stations[sid] ?? FreeDVStation(id: sid, callsign: data["callsign"] as? String ?? "",
                                               locator: data["grid_square"] as? String ?? "")
        change(&s)
        if stations[sid] != s { stations[sid] = s }
    }

    /// A JSON number, whether it arrives as an integer or a real.
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let i as Int: return Double(i)
        case let d as Double: return d
        default: return nil
        }
    }

    /// The server's timestamps: ISO 8601 with microseconds ("2026-10-09T17:45:22.482298+00:00").
    static func parseDate(_ s: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // ISO8601DateFormatter takes at most millisecond precision: cut the fraction to three digits.
        var text = s
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let digits = text[text.index(after: dot)..<end]
            text.replaceSubrange(text.index(after: dot)..<end, with: (digits + "000").prefix(3))
        }
        if let d = full.date(from: text) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: s)
    }

    // MARK: Connection

    private var wanted: Bool { isEnabled && !isPaused }

    private func reconcile() {
        guard wanted else {
            disconnect()
            if !isEnabled { stations = [:] }
            return
        }
        if transport == nil && retryTask == nil { connect() }
    }

    private func connect() {
        state = .connecting
        // The server sends the whole list again after connecting.
        stations = [:]
        let t = makeTransport(FreeDVReporter.host, ["role": "view", "protocol_version": FreeDVReporter.protocolVersion])
        t.onEvent = { [weak self] name, data in
            guard let self else { return }
            if name == "connection_successful" {
                self.consecutiveFailures = 0
                self.state = .connected
            } else {
                self.apply(name, data)
            }
        }
        t.onClose = { [weak self] message in self?.connectionClosed(message) }
        transport = t
    }

    private func connectionClosed(_ message: String?) {
        transport = nil
        consecutiveFailures += 1
        state = .failed(message ?? "Disconnected")
        let delay = min(5 * pow(2, Double(min(consecutiveFailures - 1, 10))), Self.maximumBackoff)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.reconcile()
        }
    }

    private func disconnect() {
        retryTask?.cancel()
        retryTask = nil
        if let t = transport {
            transport = nil
            t.onClose = nil
            t.onEvent = nil
            t.close()
        }
        consecutiveFailures = 0
        state = .idle
    }
}
