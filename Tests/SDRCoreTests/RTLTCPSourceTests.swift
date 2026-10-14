import XCTest
import Network
@testable import SDRCore

/// A local rtl_tcp server: sends the 12-byte header (R820T unless told otherwise), then streams I/Q bytes as fast as the client reads.
private final class FakeRTLTCPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake rtl_tcp")
    private(set) var port: UInt16 = 0

    init(tunerType: UInt8 = 5) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [queue] conn in
            conn.start(queue: queue)
            let header = Data([0x52, 0x54, 0x4c, 0x30, 0, 0, 0, tunerType, 0, 0, 0, 29])
            conn.send(content: header, completion: .contentProcessed { _ in })
            Self.stream(conn, Data(repeating: 127, count: 1 << 16))
            Self.discardCommands(conn)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw XCTSkip("could not listen on 127.0.0.1")
        }
        self.port = port
    }

    deinit { listener.cancel() }

    private static func stream(_ conn: NWConnection, _ chunk: Data) {
        conn.send(content: chunk, completion: .contentProcessed { error in
            if error == nil { stream(conn, chunk) } else { conn.cancel() }
        })
    }

    private static func discardCommands(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { _, _, isComplete, error in
            if isComplete || error != nil { conn.cancel() } else { discardCommands(conn) }
        }
    }
}

final class RTLTCPSourceTests: XCTestCase {
    /// Stopping while blocks arrive must not crash, and no block may be delivered after stop() returns.
    func testStopWhileStreaming() throws {
        let server = try FakeRTLTCPServer()
        let src = RTLTCPSource(host: "127.0.0.1", port: server.port)
        var errors: [String] = []
        src.onError = { msg in DispatchQueue.main.async { errors.append(msg) } }
        let lock = NSLock()
        var lateCalls = 0
        var total = 0
        for cycle in 0..<50 {
            var stopped = false
            var blocks = 0
            try src.start(sampleRate: 2_400_000, centerFrequency: 100_000_000) { _ in
                lock.withLock {
                    if stopped { lateCalls += 1 }
                    blocks += 1
                }
            }
            src.setCenterFrequency(100_000_000 + Double(cycle) * 1000)
            src.setGain(cycle % 2 == 0 ? nil : 200)
            // Wait for data on most cycles; stop right away on some, before the connection is even ready.
            if cycle % 5 != 0 {
                let deadline = Date() + 2
                while lock.withLock({ blocks }) < 3, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                XCTAssertGreaterThanOrEqual(lock.withLock { blocks }, 3, "cycle \(cycle) received data")
            }
            src.stop()
            lock.withLock {
                stopped = true
                total += blocks
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(lock.withLock { lateCalls }, 0)
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(src.tunerName, "R820T/R860")
        RunLoop.main.run(until: Date() + 0.1)
        XCTAssertEqual(errors, [])
    }

    /// The tuner info from the header is readable from another thread once onInfoChanged fires.
    func testTunerInfoFromHeader() throws {
        let server = try FakeRTLTCPServer(tunerType: 1)
        let src = RTLTCPSource(host: "127.0.0.1", port: server.port)
        let info = DispatchSemaphore(value: 0)
        src.onInfoChanged = { info.signal() }
        try src.start(sampleRate: 2_400_000, centerFrequency: 100_000_000) { _ in }
        defer { src.stop() }
        XCTAssertEqual(info.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(src.tunerName, "E4000")
        XCTAssertEqual(src.gains, TunerGains.e4000)
        XCTAssertEqual(src.displayName, "rtl_tcp 127.0.0.1:\(server.port) · E4000")
    }
}
