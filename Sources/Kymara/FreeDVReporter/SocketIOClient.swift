import Foundation

/// A connection to a FreeDV Reporter server, as `FreeDVReporter` sees it (a fake in tests).
@MainActor
protocol ReporterTransport: AnyObject {
    /// A Socket.IO event from the server, with its first argument when that is a JSON object.
    var onEvent: ((String, [String: Any]) -> Void)? { get set }
    /// The connection closed or failed; the message is nil after `close()`.
    var onClose: ((String?) -> Void)? { get set }
    func emit(_ event: String, _ data: [String: Any])
    func close()
}

/// Engine.IO v4 / Socket.IO v5 packets, the subset a reporting client needs.
enum SocketIOPacket: Equatable {
    struct Event: Equatable {
        var name: String
        var data: [String: AnyHashable]
    }

    /// Engine.IO open; the session is ready for the Socket.IO connect. Intervals in ms.
    case open(pingInterval: Int, pingTimeout: Int)
    case ping
    /// Socket.IO connect accepted.
    case connected
    /// Socket.IO connect refused, or the server disconnected us.
    case refused(String)
    case event(String, [String: AnyHashable])
    /// FreeDV Reporter's `bulk_update`: a batch of events (the station list sent after connecting).
    case bulk([Event])
    case other

    static func parse(_ text: String) -> SocketIOPacket {
        if text.hasPrefix("0") {
            let json = try? JSONSerialization.jsonObject(with: Data(text.dropFirst().utf8)) as? [String: Any]
            return .open(pingInterval: json?["pingInterval"] as? Int ?? 25000,
                         pingTimeout: json?["pingTimeout"] as? Int ?? 20000)
        }
        if text == "2" { return .ping }
        if text.hasPrefix("40") { return .connected }
        if text.hasPrefix("44") {
            let json = try? JSONSerialization.jsonObject(with: Data(text.dropFirst(2).utf8)) as? [String: Any]
            return .refused(json?["message"] as? String ?? "Connection refused by the server")
        }
        if text.hasPrefix("41") { return .refused("Disconnected by the server") }
        if text.hasPrefix("42"),
           let array = try? JSONSerialization.jsonObject(with: Data(text.dropFirst(2).utf8)) as? [Any],
           let name = array.first as? String {
            if name == "bulk_update", let items = array.dropFirst().first as? [Any] {
                return .bulk(items.compactMap { item in
                    guard let pair = item as? [Any], let name = pair.first as? String else { return nil }
                    return Event(name: name, data: (pair.dropFirst().first as? [String: Any]).map(hashable) ?? [:])
                })
            }
            let data = (array.dropFirst().first as? [String: Any]).map(hashable) ?? [:]
            return .event(name, data)
        }
        return .other
    }

    /// `40{auth}`: the Socket.IO connect to the default namespace.
    static func connect(auth: [String: Any]) -> String {
        "40" + json(auth)
    }

    /// `42["name",{data}]`, or `42["name"]` when there is no data.
    static func event(_ name: String, _ data: [String: Any]?) -> String {
        "42" + json(data.map { [name, $0] } ?? [name])
    }

    private static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func hashable(_ dict: [String: Any]) -> [String: AnyHashable] {
        dict.compactMapValues { $0 as? AnyHashable }
    }
}

/// Engine.IO liveness: the server pings every `pingInterval` and expects a pong within `pingTimeout`, so silence for
/// longer than both together means the connection is dead (a half-open socket after a network change or sleep).
struct SocketIOWatchdog {
    let timeout: TimeInterval
    private(set) var deadline: Date

    init(pingInterval: Int, pingTimeout: Int, now: Date) {
        timeout = Double(pingInterval + pingTimeout) / 1000
        deadline = now + timeout
    }

    /// A packet arrived.
    mutating func reset(now: Date) {
        deadline = now + timeout
    }

    func expired(now: Date) -> Bool {
        now >= deadline
    }
}

/// Socket.IO client over `URLSessionWebSocketTask` (websocket transport only, no polling fallback).
@MainActor
final class SocketIOClient: ReporterTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onClose: ((String?) -> Void)?

    private let task: URLSessionWebSocketTask
    private let auth: [String: Any]
    private var closed = false
    private var watchdog: SocketIOWatchdog?
    private var watchdogTask: Task<Void, Never>?

    /// Connects to `host` (`wss://<host>/socket.io/`) and sends `auth` with the Socket.IO connect.
    init(host: String, auth: [String: Any], session: URLSession = .shared) {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = "/socket.io/"
        components.queryItems = [URLQueryItem(name: "EIO", value: "4"), URLQueryItem(name: "transport", value: "websocket")]
        task = session.webSocketTask(with: components.url!)
        self.auth = auth
        task.resume()
        receive()
    }

    func emit(_ event: String, _ data: [String: Any]) {
        send(SocketIOPacket.event(event, data))
    }

    func close() {
        guard !closed else { return }
        closed = true
        watchdogTask?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        onClose?(nil)
    }

    private func send(_ text: String) {
        guard !closed else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.fail(error.localizedDescription) }
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if case .success = result { self.watchdog?.reset(now: Date()) }
                switch result {
                case .success(.string(let text)):
                    self.handle(text)
                    self.receive()
                case .success:
                    self.receive()
                case .failure(let error):
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ text: String) {
        switch SocketIOPacket.parse(text) {
        case .open(let pingInterval, let pingTimeout):
            startWatchdog(pingInterval: pingInterval, pingTimeout: pingTimeout)
            send(SocketIOPacket.connect(auth: auth))
        case .ping: send("3")
        case .connected, .other: break
        case .refused(let message): fail(message)
        case .event(let name, let data): onEvent?(name, data)
        case .bulk(let events): for e in events { onEvent?(e.name, e.data) }
        }
    }

    /// Fails the connection once no packet has arrived before the watchdog's deadline.
    private func startWatchdog(pingInterval: Int, pingTimeout: Int) {
        watchdog = SocketIOWatchdog(pingInterval: pingInterval, pingTimeout: pingTimeout, now: Date())
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while let deadline = self?.watchdog?.deadline {
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                guard !Task.isCancelled, let self else { return }
                if self.watchdog?.expired(now: Date()) == true {
                    self.fail("Connection timed out")
                    return
                }
            }
        }
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        closed = true
        watchdogTask?.cancel()
        task.cancel(with: .goingAway, reason: nil)
        onClose?(message)
    }
}
