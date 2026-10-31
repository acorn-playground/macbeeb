import AppKit
import SwiftUI

/// The MCP menu: how to connect an agent, and what agents have done.
struct MCPMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Connect an AI Agent…") { openWindow(id: MCPSetupView.windowID) }
        Button("Activity Log") { openWindow(id: AgentLogView.windowID) }
            .keyboardShortcut("l", modifiers: [.command, .option])
    }
}

/// How to point Claude Code and Codex at the MCP server in this copy of the
/// app, wherever it is.
struct MCPSetupView: View {
    static let windowID = "mcp-setup"
    private let log = AgentLog.shared
    @Environment(\.openWindow) private var openWindow

    /// The MCP server, next to the app's executable.
    private static var serverURL: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("macbeeb-mcp")
    }

    private static var shellPath: String {
        "'" + serverURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static var tomlPath: String {
        "\"" + serverURL.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    var body: some View {
        Form {
            Section {
                Text("Connect an AI agent to this MacBeeb, while it's running, and it drives the BBC Micro in the window as you watch: typing, pressing keys, loading discs and tapes, reading the screen, taking screenshots and debugging.")
                Text("Add MacBeeb to your agent once with the command below. From then on, whenever MacBeeb is open, the agent attaches to it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Status") {
                    Text(status)
                        .foregroundStyle(log.serverState == .serving ? Color.secondary : Color.orange)
                }
            }

            Section {
                CommandBlock(text: "claude mcp add macbeeb -- \(Self.shellPath) --attach")
                Text("Run this in a terminal, then start Claude Code in the same folder. Add `--scope user` after `add` to have it in every project.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Claude Code")
            }

            Section {
                CommandBlock(text: "codex mcp add macbeeb -- \(Self.shellPath) --attach")
                Text("Run this in a terminal, then start Codex. Or add it to ~/.codex/config.toml yourself:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                CommandBlock(text: "[mcp_servers.macbeeb]\ncommand = \(Self.tomlPath)\nargs = [\"--attach\"]")
            } header: {
                Text("Codex")
            }

            Section {
                Text("The commands use this copy of MacBeeb, where it is now: if you move the app, add it again. MCP > Activity Log shows everything agents do here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Leave out `--attach` and the server runs a hidden BBC Micro of its own, with or without MacBeeb open. It only runs during the agent's tool calls, as fast as your Mac allows, and gives the same result every time: good for testing programs, and it leaves your BBC Micro alone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                CommandBlock(text: "claude mcp add macbeeb-headless -- \(Self.shellPath)")
                Button("AI Agents Guide") { openWindow(id: GuideWindow.windowID, value: "ai-agents") }
                    .buttonStyle(.link)
            } header: {
                Text("Headless")
            }

            Section {
                if !FileManager.default.isExecutableFile(atPath: Self.serverURL.path) {
                    Text("The server isn't at \(Self.serverURL.path).")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var status: String {
        switch log.serverState {
        case .serving:
            switch log.connections {
            case 0: "Ready to attach, no agent connected"
            case 1: "An agent is connected"
            case let n: "\(n) agents are connected"
            }
        case .notStarted: "Not started"
        case .inUse: "Another copy of MacBeeb is serving agents"
        case .failed(let reason): "Not available: \(reason)"
        }
    }
}

/// A command to copy.
private struct CommandBlock: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
        }
    }
}

/// What agents have done: each tool call, newest first, and the selected
/// one in full.
struct AgentLogView: View {
    static let windowID = "mcp-log"
    private let log = AgentLog.shared
    @State private var selection: AgentLog.Entry.ID?

    var body: some View {
        VSplitView {
            Table(entries, selection: $selection) {
                TableColumn("Time") { entry in
                    Text(entry.time, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                        .monospacedDigit()
                }
                .width(min: 90, ideal: 100)
                TableColumn("Tool") { entry in
                    switch entry.kind {
                    case .call(let tool, _, _, _, let isError, _):
                        Text(tool).foregroundStyle(isError ? Color.red : Color.primary)
                    case .connected:
                        Text("Agent connected").foregroundStyle(.secondary)
                    case .disconnected:
                        Text("Agent disconnected").foregroundStyle(.secondary)
                    }
                }
                .width(min: 100, ideal: 140)
                TableColumn("Arguments") { entry in
                    if case .call(_, let arguments, _, _, _, _) = entry.kind {
                        Text(arguments).font(.system(.body, design: .monospaced)).lineLimit(1)
                    }
                }
                .width(min: 120, ideal: 260)
                TableColumn("Result") { entry in
                    if case .call(_, _, let result, let images, let isError, _) = entry.kind {
                        Text(Self.summary(result, images: images))
                            .foregroundStyle(isError ? Color.red : Color.primary)
                            .lineLimit(1)
                    }
                }
                .width(min: 120, ideal: 260)
                TableColumn("Took") { entry in
                    if case .call(_, _, _, _, _, let duration) = entry.kind {
                        Text(Self.format(duration)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .width(min: 50, ideal: 70)
            }
            .frame(minHeight: 150)
            detail
                .frame(minHeight: 120, maxHeight: .infinity)
        }
        .overlay {
            if log.entries.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "text.badge.checkmark",
                                       description: Text("Tool calls from agents connected with macbeeb-mcp --attach appear here."))
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Clear", systemImage: "trash") {
                    selection = nil
                    log.clear()
                }
                .disabled(log.entries.isEmpty)
            }
        }
        .navigationTitle("MCP Activity")
        .frame(minWidth: 640, minHeight: 360)
    }

    private var entries: [AgentLog.Entry] { log.entries.reversed() }

    @ViewBuilder private var detail: some View {
        if let entry = log.entries.first(where: { $0.id == selection }),
           case .call(let tool, let arguments, let result, let images, let isError, let duration) = entry.kind {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(tool) — \(Self.format(duration))\(isError ? " — failed" : "")").font(.headline)
                    if !arguments.isEmpty {
                        Text(arguments).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                    Divider()
                    if !result.isEmpty {
                        Text(result).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                    ForEach(images.indices, id: \.self) { index in
                        if let image = NSImage(data: images[index]) {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 480, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else {
            Text("Select a call to see it in full.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func summary(_ result: String, images: [Data]) -> String {
        let first = result.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        switch (first.isEmpty, images.count) {
        case (_, 0): return first
        case (true, let n): return n == 1 ? "Image" : "\(n) images"
        case (false, let n): return first + (n == 1 ? " + image" : " + \(n) images")
        }
    }

    private static func format(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return ms < 1000 ? String(format: "%.0f ms", ms) : String(format: "%.2f s", ms / 1000)
    }
}
