import Foundation
import Observation

/// Reports RADE reception to FreeDV Reporter (qso.freedv.org), the live map of FreeDV activity, as a
/// receive-only station: our callsign, locator and frequency, and the callsigns we decode with their SNR.
/// The protocol follows freedv-backend's `FreeDVReporter.cpp`. `RadioController` drives it from its status
/// poll; it is connected only while enabled, configured and `active` (the radio runs in RADE mode).
@MainActor
@Observable
final class FreeDVReporter {
    static let host = "qso.freedv.org"
    static let modeName = "RADEV1"
    static let protocolVersion = 2
    /// While in sync without a decoded callsign, a report with an empty callsign this often, so the map
    /// shows that we hear *something* (freedv-gui does the same).
    static let syncReportInterval: TimeInterval = 10
    /// Frequency and settings changes wait this long, so dragging the VFO or typing doesn't flood the server.
    static let settleTime: TimeInterval = 1
    static let maximumBackoff: TimeInterval = 300

    enum State: Equatable {
        case idle, connecting, connected
        /// Waiting to retry after the connection failed or was refused.
        case failed(String)
    }

    var isEnabled = false { didSet { if isEnabled != oldValue { settingsChanged() } } }
    var callsign = "" { didSet { if callsign != oldValue { settingsChanged() } } }
    var locator = "" { didSet { if locator != oldValue { settingsChanged() } } }
    /// Free text shown with our station on the map (freedv-gui's status message). Changing it doesn't reconnect.
    var message = "" {
        didSet {
            guard message != oldValue else { return }
            if !loading { persistence?.saveFreeDVReporter(settings) }
            messageChangedAt = now()
        }
    }
    private(set) var state: State = .idle

    /// Whether the callsign and locator are good enough to report with.
    var isConfigured: Bool { Self.normalizedCallsign(callsign) != nil && Self.normalizedLocator(locator) != nil }

    @ObservationIgnored private let makeTransport: @MainActor (String, [String: Any]) -> ReporterTransport
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let persistence: SettingsStore?
    @ObservationIgnored private let version: String
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var frequency = 0
    @ObservationIgnored private var frequencyChangedAt: Date?
    @ObservationIgnored private var sentFrequency: Int?
    @ObservationIgnored private var settingsChangedAt: Date?
    @ObservationIgnored private var messageChangedAt: Date?
    @ObservationIgnored private var sentMessage: String?
    @ObservationIgnored private var transport: ReporterTransport?
    @ObservationIgnored private var isFullyConnected = false
    @ObservationIgnored private(set) var consecutiveFailures = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var lastReport: Date?

    init(persistence: SettingsStore? = nil,
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
         now: @escaping () -> Date = Date.init,
         makeTransport: @escaping @MainActor (String, [String: Any]) -> ReporterTransport = { SocketIOClient(host: $0, auth: $1) }) {
        self.persistence = persistence
        self.version = version
        self.now = now
        self.makeTransport = makeTransport
        if let saved = persistence?.loadFreeDVReporter() {
            loading = true
            settings = saved
            loading = false
        }
    }

    var settings: FreeDVReporterSettings {
        get { FreeDVReporterSettings(enabled: isEnabled, callsign: callsign, locator: locator, message: message) }
        set {
            callsign = newValue.callsign
            locator = newValue.locator
            message = newValue.message
            isEnabled = newValue.enabled
        }
    }

    // MARK: Driven by RadioController

    /// Called from the status poll (and on stop). Connects or disconnects as `active` changes, and sends
    /// frequency and settings changes once they have settled.
    func update(active: Bool, frequency: Double) {
        let f = Int(frequency.rounded())
        if f != self.frequency {
            self.frequency = f
            frequencyChangedAt = now()
        }
        if active != self.active {
            self.active = active
            lastReport = nil
            reconcile()
        }
        if let t = settingsChangedAt, now().timeIntervalSince(t) >= Self.settleTime {
            settingsChangedAt = nil
            disconnect()
            reconcile()
        }
        if isFullyConnected, let t = frequencyChangedAt, now().timeIntervalSince(t) >= Self.settleTime {
            frequencyChangedAt = nil
            sendFrequency()
        }
        if isFullyConnected, let t = messageChangedAt, now().timeIntervalSince(t) >= Self.settleTime {
            messageChangedAt = nil
            sendMessage()
        }
    }

    /// A callsign decoded from an end-of-over, or nil while in sync without one (sent every
    /// `syncReportInterval`). Ignored unless connected.
    func heard(callsign: String?, snr: Float) {
        guard isFullyConnected, active else { return }
        let t = now()
        if callsign == nil, let last = lastReport, t.timeIntervalSince(last) < Self.syncReportInterval { return }
        lastReport = t
        transport?.emit("rx_report", ["callsign": callsign ?? "", "mode": Self.modeName,
                                      "snr": Int(snr.rounded())])
    }

    // MARK: Connection

    private func settingsChanged() {
        guard !loading else { return }
        persistence?.saveFreeDVReporter(settings)
        settingsChangedAt = now()
    }

    private var wanted: Bool { isEnabled && isConfigured && active }

    private func reconcile() {
        guard wanted else {
            disconnect()
            return
        }
        if transport == nil && retryTask == nil { connect() }
    }

    var auth: [String: Any] {
        [
            "role": "report",
            "callsign": Self.normalizedCallsign(callsign) ?? "",
            "grid_square": Self.normalizedLocator(locator) ?? "",
            "version": "Kymara \(version)",
            "rx_only": true,
            "os": "macos",
            "protocol_version": Self.protocolVersion,
        ]
    }

    private func connect() {
        // The connection uses the current settings, so a pending settings change is taken care of.
        settingsChangedAt = nil
        state = .connecting
        let t = makeTransport(Self.host, auth)
        t.onEvent = { [weak self] name, _ in
            if name == "connection_successful" { self?.connectionSucceeded() }
        }
        t.onClose = { [weak self] message in self?.connectionClosed(message) }
        transport = t
    }

    /// The server sends `connection_successful` once it has registered us; only then does it accept reports.
    private func connectionSucceeded() {
        isFullyConnected = true
        consecutiveFailures = 0
        state = .connected
        sendFrequency()
        transport?.emit("tx_report", ["mode": Self.modeName, "transmitting": false])
        sendMessage()
    }

    private func sendMessage() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != sentMessage else { return }
        sentMessage = text
        transport?.emit("message_update", ["message": text])
    }

    private func sendFrequency() {
        guard frequency != sentFrequency else { return }
        sentFrequency = frequency
        transport?.emit("freq_change", ["freq": frequency])
    }

    private func connectionClosed(_ message: String?) {
        transport = nil
        isFullyConnected = false
        sentFrequency = nil
        sentMessage = nil
        consecutiveFailures += 1
        state = .failed(message ?? "Disconnected")
        let delay = retryDelay
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.reconcile()
        }
    }

    /// 5 s after the first failure, doubling up to `maximumBackoff`.
    var retryDelay: TimeInterval {
        min(5 * pow(2, Double(min(max(consecutiveFailures - 1, 0), 10))), Self.maximumBackoff)
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
        isFullyConnected = false
        sentFrequency = nil
        sentMessage = nil
        consecutiveFailures = 0
        state = .idle
    }

    // MARK: Validation

    /// Upper-cased callsign (letters, digits and `/`, with at least one of each of letters and digits), or nil.
    static func normalizedCallsign(_ s: String) -> String? {
        let call = s.trimmingCharacters(in: .whitespaces).uppercased()
        guard call.count >= 3, call.count <= 15,
              call.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "/" }),
              call.contains(where: \.isLetter), call.contains(where: \.isNumber) else { return nil }
        return call
    }

    /// A 4- or 6-character Maidenhead locator written the usual way (`JO22` or `JO22ab`), or nil.
    static func normalizedLocator(_ s: String) -> String? {
        let chars = Array(s.trimmingCharacters(in: .whitespaces))
        guard chars.count == 4 || chars.count == 6 else { return nil }
        let field = String(chars[0...1]).uppercased(), square = String(chars[2...3])
        guard field.allSatisfy({ ("A"..."R").contains($0) }), square.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        guard chars.count == 6 else { return field + square }
        let sub = String(chars[4...5]).lowercased()
        guard sub.allSatisfy({ ("a"..."x").contains($0) }) else { return nil }
        return field + square + sub
    }
}
