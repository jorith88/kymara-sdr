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

    private let queue = DispatchQueue(label: "rtl_tcp", qos: .userInteractive)
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
    }

    deinit { stop() }

    public func start(sampleRate: Double, centerFrequency: Double, handler: @escaping IQHandler) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SourceError.connectionFailed("invalid port \(port)")
        }
        self.sampleRate = sampleRate
        self.center = centerFrequency
        self.handler = handler
        headerBytes = Data()
        leftover = nil
        stopped = false

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendInitialConfig()
                self.receive()
            case .failed(let error):
                if !self.stopped { self.onError?("rtl_tcp: \(error.localizedDescription)") }
            case .waiting(let error):
                if !self.stopped { self.onError?("rtl_tcp: cannot reach \(self.host):\(self.port) (\(error.localizedDescription))") }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    public func stop() {
        stopped = true
        connection?.cancel()
        connection = nil
        handler = nil
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

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if let error {
                self.onError?("rtl_tcp: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.onError?("rtl_tcp: server closed the connection")
                return
            }
            self.receive()
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
        center = hz
        queue.async { self.send(0x01, UInt32(clamping: Int64(hz))) }
    }

    public func setGain(_ tenthsDB: Int?) {
        gain = tenthsDB
        queue.async { self.sendGain() }
    }

    public func setPPM(_ ppm: Int) {
        self.ppm = ppm
        queue.async { self.send(0x05, UInt32(bitPattern: Int32(ppm))) }
    }

    public func setRTLAGC(_ on: Bool) {
        rtlAGC = on
        queue.async { self.send(0x08, on ? 1 : 0) }
    }

    public func setDirectSampling(_ mode: Int) {
        directSampling = mode
        queue.async { self.send(0x09, UInt32(mode)) }
    }

    public func setBiasTee(_ on: Bool) {
        biasTee = on
        queue.async { self.send(0x0e, on ? 1 : 0) }
    }

    public func setOffsetTuning(_ on: Bool) {
        offsetTuning = on
        queue.async { self.send(0x0a, on ? 1 : 0) }
    }
}
