#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

#if canImport(Glibc)
/// Glibc has SOCK_STREAM as an enum case.
private let SOCK_STREAM = Int32(Glibc.SOCK_STREAM.rawValue)
#endif

/// read(2) and write(2) by their own names, as the Mac's Darwin.read and
/// Darwin.write; on Linux, writing is send(2) without SIGPIPE, so an agent
/// that goes away mid-reply can't take the process with it.
private func socketRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(fd, buffer, count)
    #else
    Glibc.read(fd, buffer, count)
    #endif
}

private func socketWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(fd, buffer, count)
    #else
    send(fd, buffer, count, Int32(MSG_NOSIGNAL))
    #endif
}

/// The local socket the app serves agent tools on, so `macbeeb-mcp
/// --attach` can drive the machine you're watching. One JSON object per
/// line each way: {"tool": name, "arguments": {...}} in, a CallToolResult
/// out. The socket is only accessible to the user.
public enum AgentSocket {
    public static var defaultPath: String {
        #if os(Linux)
        // Linux keeps sockets in the user's runtime directory (private,
        // and cleared at logout), when there is one.
        let base = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let support = base.appendingPathComponent("MacBeeb", isDirectory: true)
        #else
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacBeeb", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("agent.sock").path
    }

    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    /// Reads lines from a socket.
    final class LineReader {
        let fd: Int32
        var buffer = Data()
        init(fd: Int32) { self.fd = fd }

        func readLine() -> String? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return String(decoding: line, as: UTF8.self)
                }
                var chunk = [UInt8](repeating: 0, count: 65536)
                let n = socketRead(fd, &chunk, chunk.count)
                guard n > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<n])
            }
        }
    }

    static func writeLine(_ fd: Int32, _ value: JSONValue) -> Bool {
        guard var data = try? JSONEncoder().encode(value) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = socketWrite(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}

/// Serves agent tools on the agent socket (in the app).
public final class AgentSocketServer: @unchecked Sendable {
    let tools: ToolProvider
    let path: String
    private var listener: Int32 = -1
    /// Called (on the connection's thread) when an agent connects (true) or
    /// goes (false). Set before `start`.
    public var onConnection: (@Sendable (Bool) -> Void)?

    public init(tools: ToolProvider, path: String = AgentSocket.defaultPath) {
        self.tools = tools
        self.path = path
    }

    /// Whether something accepts connections on the socket at `path`.
    static func isLive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = AgentSocket.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0
    }

    public enum StartError: Error {
        /// Another app is serving the socket.
        case inUse
    }

    public func start() throws {
        // Another MacBeeb already serving it keeps it.
        if Self.isLive(path) {
            throw StartError.inUse
        }
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = AgentSocket.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 4) == 0 else {
            close(listener)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let thread = Thread { [unowned self] in self.acceptLoop() }
        thread.name = "Agent socket"
        thread.start()
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            let thread = Thread { [unowned self] in self.serve(client) }
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        onConnection?(true)
        defer {
            close(fd)
            onConnection?(false)
        }
        let reader = AgentSocket.LineReader(fd: fd)
        while let line = reader.readLine() {
            guard let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  let name = request["tool"]?.stringValue else {
                _ = AgentSocket.writeLine(fd, ToolResult.error("bad request").json)
                continue
            }
            let result = tools.call(name, arguments: request["arguments"] ?? [:])
            guard AgentSocket.writeLine(fd, result.json) else { return }
        }
    }
}

/// Forwards tool calls to the app (in macbeeb-mcp --attach).
public final class AppConnection: ToolProvider, @unchecked Sendable {
    let path: String
    private var fd: Int32 = -1
    private var reader: AgentSocket.LineReader?
    private let lock = NSLock()

    public init(path: String = AgentSocket.defaultPath) {
        self.path = path
    }

    private func connectIfNeeded() -> Bool {
        if fd >= 0 { return true }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var address = AgentSocket.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(s)
            return false
        }
        fd = s
        reader = AgentSocket.LineReader(fd: s)
        return true
    }

    public func call(_ name: String, arguments: JSONValue) -> ToolResult {
        // Paths are relative to the agent, not the app.
        var arguments = arguments
        if case .object(var object) = arguments, let path = object["path"]?.stringValue,
           !path.hasPrefix("/"), !path.hasPrefix("~") {
            object["path"] = .string(URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path)
            arguments = .object(object)
        }
        lock.lock()
        defer { lock.unlock() }
        // One retry, in case the app restarted.
        for _ in 0..<2 {
            guard connectIfNeeded() else {
                return .error("MacBeeb isn't running (no agent socket at \(path)). Open the app, or run macbeeb-mcp without --attach for a headless machine.")
            }
            if AgentSocket.writeLine(fd, ["tool": .string(name), "arguments": arguments]),
               let line = reader?.readLine(),
               let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) {
                return ToolResult(json: json)
            }
            close(fd)
            fd = -1
        }
        return .error("lost the connection to MacBeeb")
    }
}
