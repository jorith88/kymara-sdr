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
    /// Engine.IO open; the session is ready for the Socket.IO connect.
    case open
    case ping
    /// Socket.IO connect accepted.
    case connected
    /// Socket.IO connect refused, or the server disconnected us.
    case refused(String)
    case event(String, [String: AnyHashable])
    case other

    static func parse(_ text: String) -> SocketIOPacket {
        if text.hasPrefix("0") { return .open }
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

/// Socket.IO client over `URLSessionWebSocketTask` (websocket transport only, no polling fallback).
@MainActor
final class SocketIOClient: ReporterTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onClose: ((String?) -> Void)?

    private let task: URLSessionWebSocketTask
    private let auth: [String: Any]
    private var closed = false

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
        case .open: send(SocketIOPacket.connect(auth: auth))
        case .ping: send("3")
        case .connected, .other: break
        case .refused(let message): fail(message)
        case .event(let name, let data): onEvent?(name, data)
        }
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
        onClose?(message)
    }
}
