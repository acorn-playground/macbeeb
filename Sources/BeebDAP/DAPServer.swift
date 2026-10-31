// Serves DAP on a localhost TCP port (VS Code connects with a
// DebugAdapterServer). One client at a time; a new one replaces the old.

import BeebAgentKit
import BeebCore
import BeebHost
import Foundation
#if canImport(Network)
import Network
#elseif canImport(Glibc)
import Glibc
#endif

public final class DAPServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 6502

    private let host: EmulatorHost
    private let changeMachine: @Sendable (BBCMicro.Model, Bool) -> Void
    private let queue = DispatchQueue(label: "MacBeeb DAP")
    #if canImport(Network)
    private var listener: NWListener?
    private var connection: NWConnection?
    #else
    /// The listening socket, and the client's (on Linux, POSIX sockets).
    private var listenerSocket: Int32 = -1
    private var connectionSocket: Int32 = -1
    #endif
    private var session: DAPSession?
    private var buffer = Data()
    public private(set) var port: UInt16

    public init(host: EmulatorHost, port: UInt16 = defaultPort,
                changeMachine: @escaping @Sendable (BBCMicro.Model, Bool) -> Void = { _, _ in }) {
        self.host = host
        self.port = port
        self.changeMachine = changeMachine
    }

#if canImport(Network)
    /// Starts listening on 127.0.0.1. With port 0, picks a free one
    /// (`port` says which, once `ready` is called).
    public func start(ready: @escaping @Sendable (UInt16) -> Void = { _ in }) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let self, let port = listener.port?.rawValue {
                self.port = port
                ready(port)
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        connection?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        buffer = Data()
        let session = DAPSession(host: host, send: { [weak self, weak connection] message in
            guard let connection, let data = try? Self.frame(message) else { return }
            self?.queue.async { connection.send(content: data, completion: .contentProcessed { _ in }) }
        }, changeMachine: changeMachine)
        self.session = session
        connection.start(queue: queue)
        receive(connection, session)
    }

    private func receive(_ connection: NWConnection, _ session: DAPSession) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data {
                self.buffer.append(data)
                for message in Self.messages(from: &self.buffer) {
                    // In order: each waits for the last.
                    let previous = self.pending
                    self.pending = Task {
                        await previous?.value
                        await session.handle(message)
                    }
                }
            }
            if complete || error != nil {
                Task { await session.handle(["type": "request", "seq": 0, "command": "disconnect"]) }
                connection.cancel()
                return
            }
            self.receive(connection, session)
        }
    }

#else
    /// Starts listening on 127.0.0.1. With port 0, picks a free one
    /// (`port` says which, once `ready` is called).
    public func start(ready: @escaping @Sendable (UInt16) -> Void = { _ in }) throws {
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard listener >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(listener)
            throw error
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        listenerSocket = listener
        let port = port
        queue.async { ready(port) }
        let thread = Thread { [weak self] in
            while true {
                let client = Glibc.accept(listener, nil, nil)
                guard client >= 0 else { return }
                guard let self else { close(client); return }
                self.queue.async { self.accept(client) }
            }
        }
        thread.name = "MacBeeb DAP"
        thread.start()
    }

    public func stop() {
        queue.sync {
            if listenerSocket >= 0 {
                shutdown(listenerSocket, Int32(SHUT_RDWR))
                close(listenerSocket)
                listenerSocket = -1
            }
            if connectionSocket >= 0 {
                shutdown(connectionSocket, Int32(SHUT_RDWR))
            }
        }
    }

    /// On the queue.
    private func accept(_ client: Int32) {
        if connectionSocket >= 0 {
            // A new client replaces the old: its reader sees the end.
            shutdown(connectionSocket, Int32(SHUT_RDWR))
        }
        connectionSocket = client
        buffer = Data()
        let session = DAPSession(host: host, send: { [weak self] message in
            guard let self, let data = try? Self.frame(message) else { return }
            self.queue.async {
                guard self.connectionSocket == client else { return }
                data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let n = send(client, bytes.baseAddress! + offset, bytes.count - offset, Int32(MSG_NOSIGNAL))
                        if n <= 0 { return }
                        offset += n
                    }
                }
            }
        }, changeMachine: changeMachine)
        self.session = session
        let thread = Thread { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(client, &chunk, chunk.count)
                guard n > 0, let server = self else { break }
                let data = Data(chunk[0..<n])
                server.queue.async { server.received(data, session) }
            }
            guard let server = self else {
                close(client)
                return
            }
            server.queue.async {
                Task { await session.handle(["type": "request", "seq": 0, "command": "disconnect"]) }
                if server.connectionSocket == client {
                    server.connectionSocket = -1
                }
                close(client)
            }
        }
        thread.name = "MacBeeb DAP connection"
        thread.start()
    }

    /// On the queue.
    private func received(_ data: Data, _ session: DAPSession) {
        buffer.append(data)
        for message in Self.messages(from: &buffer) {
            // In order: each waits for the last.
            let previous = pending
            pending = Task {
                await previous?.value
                await session.handle(message)
            }
        }
    }

#endif

    private var pending: Task<Void, Never>?

    // MARK: Framing

    /// `Content-Length: n\r\n\r\n` then n bytes of JSON.
    static func frame(_ message: JSONValue) throws -> Data {
        let body = try JSONEncoder().encode(message)
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    /// The complete messages at the start of `buffer`, removed from it.
    static func messages(from buffer: inout Data) -> [JSONValue] {
        var messages: [JSONValue] = []
        let separator = Data("\r\n\r\n".utf8)
        while let end = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            guard let line = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) else {
                // Not a header we understand: drop it.
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                continue
            }
            let bodyStart = end.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            if let message = try? JSONDecoder().decode(JSONValue.self, from: buffer[bodyStart..<bodyEnd]) {
                messages.append(message)
            }
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            buffer = Data(buffer)
        }
        return messages
    }
}
