import Foundation
import Network

/// Client for the rtl_tcp protocol (12-byte header, raw u8 I/Q stream, 5-byte commands).
public final class RTLTCPSource: IQSource, @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public var displayName: String { "rtl_tcp \(host):\(port)" + (tunerName.isEmpty ? "" : " · \(tunerName)") }
    public private(set) var gains: [Int] = TunerGains.r820t
    public private(set) var tunerName = ""
    public var onError: ((String) -> Void)?
    public var onInfoChanged: (() -> Void)?

    /// All connection and stream state below is only touched on this queue.
    private let queue = DispatchQueue(label: "rtl_tcp", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()
    private var connection: NWConnection?
    private var handler: IQHandler?
    private var headerBytes = Data()
    private var leftover: UInt8?
    private var stopped = true

    private var sampleRate: Double = 2_400_000
    private var center: Double = 100_000_000
    private var gain: Int? = nil
    private var ppm = 0
    private var rtlAGC = false
    private var directSampling = 0
    private var biasTee = false
    private var offsetTuning = false

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { stop() }

    public func start(sampleRate: Double, centerFrequency: Double, handler: @escaping IQHandler) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SourceError.connectionFailed("invalid port \(port)")
        }
        onQueue {
            stopOnQueue()
            self.sampleRate = sampleRate
            self.center = centerFrequency
            self.handler = handler
            headerBytes = Data()
            leftover = nil
            stopped = false
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            connection = conn
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                self?.connectionStateChanged(state, conn)
            }
            conn.start(queue: queue)
        }
    }

    public func stop() {
        onQueue { stopOnQueue() }
    }

    /// Runs `body` on `queue`, directly when already on it (deinit can run there), so it never deadlocks.
    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    private func stopOnQueue() {
        stopped = true
        connection?.cancel()
        connection = nil
        handler = nil
    }

    /// Events of `conn`; ignored once it is no longer the current connection (stopped, or replaced by a restart).
    private func connectionStateChanged(_ state: NWConnection.State, _ conn: NWConnection?) {
        guard let conn, conn === connection else { return }
        switch state {
        case .ready:
            sendInitialConfig()
            receive(conn)
        case .failed(let error):
            if !stopped { onError?("rtl_tcp: \(error.localizedDescription)") }
        case .waiting(let error):
            if !stopped { onError?("rtl_tcp: cannot reach \(host):\(port) (\(error.localizedDescription))") }
        default:
            break
        }
    }

    private func sendInitialConfig() {
        send(0x02, UInt32(sampleRate))
        send(0x09, UInt32(directSampling))
        send(0x0a, offsetTuning ? 1 : 0)
        send(0x01, UInt32(clamping: Int64(center)))
        send(0x05, UInt32(bitPattern: Int32(ppm)))
        send(0x08, rtlAGC ? 1 : 0)
        sendGain()
        send(0x0e, biasTee ? 1 : 0)
    }

    private func send(_ command: UInt8, _ value: UInt32) {
        guard let connection, !stopped else { return }
        var bytes = Data([command])
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
        connection.send(content: bytes, completion: .contentProcessed { _ in })
    }

    private func sendGain() {
        if let gain {
            send(0x03, 1)
            send(0x04, UInt32(bitPattern: Int32(gain)))
        } else {
            send(0x03, 0)
        }
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, conn === self.connection, !self.stopped else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if let error {
                self.onError?("rtl_tcp: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.onError?("rtl_tcp: server closed the connection")
                return
            }
            self.receive(conn)
        }
    }

    private func consume(_ incoming: Data) {
        var data = incoming
        if headerBytes.count < 12 {
            let need = 12 - headerBytes.count
            headerBytes.append(data.prefix(need))
            data = data.dropFirst(min(need, data.count))
            if headerBytes.count == 12 { parseHeader() }
            if data.isEmpty { return }
        }
        if let l = leftover {
            data.insert(l, at: data.startIndex)
            leftover = nil
        }
        if data.count % 2 == 1 {
            leftover = data.last
            data = data.dropLast()
        }
        guard !data.isEmpty, let handler else { return }
        data.withUnsafeBytes { raw in
            handler(.u8(raw.bindMemory(to: UInt8.self)))
        }
    }

    private func parseHeader() {
        let bytes = [UInt8](headerBytes)
        guard bytes.count == 12, bytes[0] == 0x52, bytes[1] == 0x54, bytes[2] == 0x4c, bytes[3] == 0x30 else { return }
        let type = Int(UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]))
        tunerName = TunerGains.tunerName(type)
        gains = TunerGains.forTunerType(type)
        onInfoChanged?()
    }

    public func setCenterFrequency(_ hz: Double) {
        queue.async {
            self.center = hz
            self.send(0x01, UInt32(clamping: Int64(hz)))
        }
    }

    public func setGain(_ tenthsDB: Int?) {
        queue.async {
            self.gain = tenthsDB
            self.sendGain()
        }
    }

    public func setPPM(_ ppm: Int) {
        queue.async {
            self.ppm = ppm
            self.send(0x05, UInt32(bitPattern: Int32(ppm)))
        }
    }

    public func setRTLAGC(_ on: Bool) {
        queue.async {
            self.rtlAGC = on
            self.send(0x08, on ? 1 : 0)
        }
    }

    public func setDirectSampling(_ mode: Int) {
        queue.async {
            self.directSampling = mode
            self.send(0x09, UInt32(mode))
        }
    }

    public func setBiasTee(_ on: Bool) {
        queue.async {
            self.biasTee = on
            self.send(0x0e, on ? 1 : 0)
        }
    }

    public func setOffsetTuning(_ on: Bool) {
        queue.async {
            self.offsetTuning = on
            self.send(0x0a, on ? 1 : 0)
        }
    }
}
