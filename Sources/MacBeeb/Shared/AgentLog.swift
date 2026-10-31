import BeebAgentKit
import Foundation
import Observation

/// What agents have done through `macbeeb-mcp --attach`: each tool call,
/// with its arguments and result, and agents coming and going. For MCP >
/// Activity Log.
@MainActor
@Observable
final class AgentLog {
    static let shared = AgentLog()
    /// Older entries are dropped.
    static let limit = 1000

    struct Entry: Identifiable {
        enum Kind {
            case call(tool: String, arguments: String, result: String, images: [Data], isError: Bool, duration: Duration)
            case connected
            case disconnected
        }

        let id = UUID()
        let time: Date
        let kind: Kind
    }

    enum ServerState: Equatable {
        case notStarted
        case serving
        /// Another MacBeeb has the socket.
        case inUse
        case failed(String)
    }

    private(set) var entries: [Entry] = []
    var serverState = ServerState.notStarted
    /// Agents connected now.
    private(set) var connections = 0
    /// Tool calls running now.
    private(set) var callsRunning = 0

    func callStarted() {
        callsRunning += 1
    }

    func add(_ kind: Entry.Kind, at time: Date = Date()) {
        switch kind {
        case .connected: connections += 1
        case .disconnected: connections = max(0, connections - 1)
        case .call: callsRunning = max(0, callsRunning - 1)
        }
        entries.append(Entry(time: time, kind: kind))
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
    }

    func clear() {
        entries = []
    }
}

/// Agent tools that note each call in the `AgentLog`.
struct LoggedTools: ToolProvider {
    let tools: ToolProvider

    func call(_ name: String, arguments: JSONValue) -> ToolResult {
        let start = Date()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AgentLog.shared.callStarted() }
        }
        let clock = ContinuousClock()
        var result: ToolResult!
        let duration = clock.measure { result = tools.call(name, arguments: arguments) }
        let text = result.content.compactMap { content -> String? in
            if case .text(let text) = content { return text }
            return nil
        }.joined(separator: "\n")
        let images = result.content.compactMap { content -> Data? in
            if case .png(let data) = content { return data }
            return nil
        }
        let kind = AgentLog.Entry.Kind.call(tool: name, arguments: Self.describe(arguments), result: text, images: images,
                                            isError: result.isError, duration: duration)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AgentLog.shared.add(kind, at: start) }
        }
        return result
    }

    /// Compact JSON, keys in order.
    static func describe(_ arguments: JSONValue) -> String {
        if case .object(let fields) = arguments, fields.isEmpty {
            return ""
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(arguments)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
