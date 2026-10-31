import CGtk
import Foundation

/// AI Agents (the Mac's MCP menu): how to connect an agent, and what agents
/// have done.
@MainActor
enum AgentWindows {
    /// AI Agents > Connect an AI Agent…
    static func showConnect() {
        Windows.show("connect-agent") { AgentConnectWindow.make() }
    }

    /// AI Agents > Activity Log.
    static func showLog() {
        Windows.show("agent-log") { AgentLogWindow().window }
    }
}

/// How to point Claude Code and Codex at the MCP server in this copy of the
/// app, wherever it is: `macbeeb-mcp`, beside the app's own executable.
/// (The Mac's is MCPSetupView.)
@MainActor
enum AgentConnectWindow {
    /// The MCP server, next to the app's executable.
    static var serverURL: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("macbeeb-mcp")
    }

    private static var shellPath: String {
        "'" + serverURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static var tomlPath: String {
        "\"" + serverURL.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func make() -> Window {
        let window = Window(title: "Connect an AI Agent", width: 660, height: 760)
        window.minimumSize(width: 360, height: 360)
        let document = HelpDocument { page in
            GuideWindow.show(page: page)
            return true
        }
        func note(_ markdown: String) -> Label {
            document.text(markdown).style("dim-label")
        }

        let log = AgentLog.shared
        let status = Label("", style: "dim-label").xalign(1).ellipsize()
        status.track {
            status.text = Self.status(log)
            status.tooltip(status.text)
            status.setStyle("dim-label", log.serverState == .serving)
            status.setStyle("warning", log.serverState != .serving)
        }
        let statusRow = ActionRow("Status").suffix(status)

        let page = PreferencesPage {
            PreferencesGroup {
                Box(.vertical, spacing: 10) {
                    document.text("Connect an AI agent to this MacBeeb, while it’s running, and it drives the BBC Micro in the window as you watch: typing, pressing keys, loading discs and tapes, reading the screen, taking screenshots and debugging.")
                    note("Add MacBeeb to your agent once with the command below. From then on, whenever MacBeeb is open, the agent attaches to it.")
                }
            }
            PreferencesGroup { statusRow }
            PreferencesGroup(title: "Claude Code") {
                Box(.vertical, spacing: 10) {
                    command("claude mcp add macbeeb -- \(Self.shellPath) --attach")
                    note("Run this in a terminal, then start Claude Code in the same folder. Add `--scope user` after `add` to have it in every project.")
                }
            }
            PreferencesGroup(title: "Codex") {
                Box(.vertical, spacing: 10) {
                    command("codex mcp add macbeeb -- \(Self.shellPath) --attach")
                    note("Run this in a terminal, then start Codex. Or add it to ~/.codex/config.toml yourself:")
                    command("[mcp_servers.macbeeb]\ncommand = \(Self.tomlPath)\nargs = [\"--attach\"]")
                }
            }
            PreferencesGroup {
                note("The commands use this copy of MacBeeb, where it is now: if you move the app, add it again. AI Agents ▸ Activity Log shows everything agents do here.")
            }
            PreferencesGroup(title: "Headless") {
                Box(.vertical, spacing: 10) {
                    note("Leave out `--attach` and the server runs a hidden BBC Micro of its own, with or without MacBeeb open. It only runs during the agent’s tool calls, as fast as your computer allows, and gives the same result every time: good for testing programs, and it leaves your BBC Micro alone.")
                    command("claude mcp add macbeeb-headless -- \(Self.shellPath)")
                    document.text("[AI Agents Guide](ai-agents)")
                }
            }
            if !FileManager.default.isExecutableFile(atPath: Self.serverURL.path) {
                PreferencesGroup {
                    Label("The server isn’t at \(Self.serverURL.path).", style: "warning").wrap().selectable()
                }
            }
        }

        window.content = ToolbarView(content: page).top(HeaderBar())
        App.addStandardShortcuts(to: window)
        window.keep(document)
        // (Not the first paragraph, which focus would select.)
        gtk_window_set_focus(window.window, nil)
        return window
    }

    private static func status(_ log: AgentLog) -> String {
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

    /// A command to copy: monospace, selectable, and a Copy button.
    private static func command(_ text: String) -> Widget {
        let label = Label(text, style: "monospace").wrap().selectable().expand(horizontal: true)
        label.align(vertical: GTK_ALIGN_CENTER)
        let copy = Button("Copy").align(vertical: GTK_ALIGN_CENTER).tooltip("Copy the command")
        let life = WidgetLife(copy)
        copy.onClicked {
            Clipboard.setText(text)
            copy.label = "Copied"
            macbeeb_announce(copy.widget, "Copied")
            life.generation += 1
            let generation = life.generation
            MainLoop.after(1.5) {
                guard life.alive, life.generation == generation else { return }
                copy.label = "Copy"
            }
        }
        return Box(.horizontal, spacing: 12) { label; copy }
            .margin(top: 10, bottom: 10, start: 14, end: 10)
            .wrappedInCard()
    }
}

private extension Widget {
    func wrappedInCard() -> Widget {
        Bin(self).style("card", "help-command")
    }
}

/// What agents have done: each tool call, newest first, and the selected
/// one in full below. (The Mac's is AgentLogView.)
@MainActor
final class AgentLogWindow {
    let window: Window
    private let log = AgentLog.shared
    private let table = Table(selection: .single)
    private let detail = Box(.vertical, spacing: 10)
    private let detailScroller: ScrolledWindow
    /// What the table shows, newest first.
    private var rows: [AgentLog.Entry] = []
    private var selection: UUID?
    private var reloading = false

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init() {
        window = Window(title: "MCP Activity", width: 860, height: 600)
        window.minimumSize(width: 480, height: 360)

        detailScroller = HelpDocument.scroller(detail)
        build()
    }

    private func build() {
        table.styledColumn("Time", width: 116) { _ in ["numeric"] } text: { [weak self] row in
            guard let entry = self?.entry(row) else { return "" }
            return Self.timeFormat.string(from: entry.time)
        }
        table.styledColumn("Tool", width: 160) { [weak self] row in
            switch self?.entry(row)?.kind {
            case .call(_, _, _, _, let isError, _): isError ? ["error"] : []
            default: ["dim-label"]
            }
        } text: { [weak self] row in
            switch self?.entry(row)?.kind {
            case .call(let tool, _, _, _, _, _): tool
            case .connected: "Agent connected"
            case .disconnected: "Agent disconnected"
            case nil: ""
            }
        }
        table.styledColumn("Arguments", expand: true) { _ in ["monospace"] } text: { [weak self] row in
            guard case .call(_, let arguments, _, _, _, _) = self?.entry(row)?.kind else { return "" }
            return Self.oneLine(arguments)
        }
        table.styledColumn("Result", expand: true) { [weak self] row in
            guard case .call(_, _, _, _, let isError, _) = self?.entry(row)?.kind else { return [] }
            return isError ? ["error"] : []
        } text: { [weak self] row in
            guard case .call(_, _, let result, let images, _, _) = self?.entry(row)?.kind else { return "" }
            return Self.summary(result, images: images)
        }
        table.styledColumn("Took", width: 84, alignRight: true) { _ in ["dim-label", "numeric"] } text: { [weak self] row in
            guard case .call(_, _, _, _, _, let duration) = self?.entry(row)?.kind else { return "" }
            return Self.format(duration)
        }

        let tableScroller = ScrolledWindow(table, horizontal: GTK_POLICY_AUTOMATIC)
        tableScroller.size(height: 150)
        detailScroller.size(height: 120)
        detail.margin(top: 12, bottom: 18, start: 18, end: 18)
        let paned = Paned(.vertical, start: tableScroller, end: detailScroller, position: 300)
            .resizes(start: true, end: true)

        let empty = StatusPage(icon: "utilities-terminal-symbolic", title: "Nothing yet",
                               description: "Tool calls from agents connected with macbeeb-mcp --attach appear here.")
        let stack = Stack()
        stack.add(empty, name: "empty")
        stack.add(paned, name: "log")

        let clear = Button(icon: "edit-clear-all-symbolic").tooltip("Clear").accessibleLabel("Clear")
        clear.onClicked { [weak self] in
            self?.selection = nil
            self?.log.clear()
        }
        window.content = ToolbarView(content: stack).top(HeaderBar().start(clear))
        App.addStandardShortcuts(to: window)
        window.keep(self)

        table.onSelectionChanged { [weak self] selected in
            guard let self, !self.reloading else { return }
            self.selection = selected.first.flatMap { self.entry($0)?.id }
            self.showDetail()
        }
        let log = log
        window.track { [weak self] in
            guard let self else { return }
            let entries = log.entries
            clear.isEnabled = !entries.isEmpty
            stack.visible = entries.isEmpty ? "empty" : "log"
            self.reload(entries)
        }
    }

    private func entry(_ row: Int) -> AgentLog.Entry? {
        rows.indices.contains(row) ? rows[row] : nil
    }

    private func reload(_ entries: [AgentLog.Entry]) {
        reloading = true
        rows = entries.reversed()
        table.reload(count: rows.count)
        // The selection stays with its call as new ones arrive above it.
        if let selection, let index = rows.firstIndex(where: { $0.id == selection }) {
            table.select([index])
        } else {
            selection = nil
            table.select([])
        }
        reloading = false
        showDetail()
    }

    private var shown: UUID?

    private func showDetail() {
        let entry = rows.first { $0.id == selection }
        guard entry?.id != shown || entry == nil else { return }
        shown = entry?.id
        detail.removeAll()
        guard let entry, case .call(let tool, let arguments, let result, let images, let isError, let duration) = entry.kind else {
            detail.append(Label("Select a call to see it in full.", style: "dim-label").centred()
                .expand().align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER))
            detail.expand()
            return
        }
        detail.append(Label("\(tool) — \(Self.format(duration))\(isError ? " — failed" : "")", style: "heading")
            .wrap().selectable())
        if !arguments.isEmpty {
            detail.append(Label(arguments, style: "monospace").wrap().selectable())
        }
        detail.append(Separator())
        if !result.isEmpty {
            let label = Label(result, style: "monospace").wrap().selectable()
            if isError { label.style("error") }
            detail.append(label)
        }
        for data in images {
            guard let image = PlatformImage(encoded: data) else { continue }
            let picture = Picture(image).canShrink(true).pixelated()
            picture.accessibleLabel("Screenshot")
            let clamp = Clamp(picture, maximum: Int32(min(image.width, 480)))
            adw_clamp_set_tightening_threshold(cast(clamp.widget), Int32(min(image.width, 480)))
            detail.append(clamp.align(horizontal: GTK_ALIGN_START))
        }
    }

    // MARK: Text

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
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

extension Table {
    /// A column whose labels take style classes by row ("error",
    /// "dim-label", "numeric"…), beside its text. (The shared `column`'s
    /// labels look the same in every row.)
    func styledColumn(_ title: String, expand: Bool = false, width: Int32 = -1, alignRight: Bool = false,
                      styles: @escaping @MainActor (Int) -> [String],
                      text: @escaping @MainActor (Int) -> String) {
        let factory = gtk_signal_list_item_factory_new()!
        let column = gtk_column_view_column_new(title, factory)!
        typealias Item = @MainActor (OpaquePointer) -> Void
        let setup: Item = { item in
            let label = gtk_label_new(nil)!
            gtk_label_set_xalign(cast(label), alignRight ? 1 : 0)
            gtk_label_set_ellipsize(cast(label), PANGO_ELLIPSIZE_END)
            gtk_list_item_set_child(item, label)
        }
        let bind: Item = { item in
            guard let label = gtk_list_item_get_child(item) else { return }
            let row = Self.row(of: gtk_list_item_get_item(item))
            gtk_label_set_text(cast(label), text(row))
            for name in ["error", "dim-label", "numeric", "monospace", "warning", "success"] {
                gtk_widget_remove_css_class(label, name)
            }
            for name in styles(row) {
                gtk_widget_add_css_class(label, name)
            }
        }
        for (signal, body) in [("setup", setup), ("bind", bind)] {
            macbeeb_signal_connect(gpointer(factory), signal, unsafeBitCast(
                { (_: gpointer?, item: gpointer?, data: gpointer?) in
                    nonisolated(unsafe) let item = item, data = data
                    MainActor.assumeIsolated {
                        guard let item else { return }
                        Boxed<Item>.from(data)(OpaquePointer(item))
                    }
                } as @convention(c) (gpointer?, gpointer?, gpointer?) -> Void, to: GCallback.self),
                Boxed<Item>(body).retained, { data, _ in AnyBox.release(data) }, 0)
        }
        gtk_column_view_column_set_expand(column, expand ? 1 : 0)
        gtk_column_view_column_set_resizable(column, 1)
        if width > 0 { gtk_column_view_column_set_fixed_width(column, width) }
        gtk_column_view_append_column(cast(widget), column)
        g_object_unref(gpointer(column))
    }

    /// A row's index: its item's string.
    private static func row(of item: gpointer?) -> Int {
        guard let item, let object = macbeeb_string_object(item) else { return 0 }
        return Int(String(cString: gtk_string_object_get_string(object))) ?? 0
    }
}
