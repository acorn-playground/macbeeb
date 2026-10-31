import BeebCore
import BeebHost
import CGtk
import Foundation

// The BASIC view's sidebar: the PROC and FN calls, BASIC breakpoints (and
// stopping on errors), watches and the log. (The Mac's BasicSidebar.)

@MainActor
enum BasicSidebar {
    static func make(model: DebuggerModel) -> Widget {
        SidebarTabs(defaultsKey: "MacBeebBasicDebuggerTab", initial: "Calls", [
            ("Calls", "view-list-symbolic", BasicCallsTab(model: model).root),
            ("Breakpoints", "media-record-symbolic", BasicBreakpointsTab(model: model).root),
            ("Watch", "view-reveal-symbolic", BasicWatchTab(model: model).root),
            ("Log", "utilities-terminal-symbolic", LogTab(model: model).root),
        ])
    }
}

// MARK: Calls

@MainActor
final class BasicCallsTab {
    let model: DebuggerModel
    private(set) var root: Widget!
    private let list = ListBox()
    private let views = Stack()
    private var frames: [BasicFrame]?

    init(model: DebuggerModel) {
        self.model = model
        list.style("boxed-list").align(vertical: GTK_ALIGN_START)
        list.onActivate { [unowned self] index in
            guard let frames = self.frames, frames.indices.contains(index), let line = frames[index].location?.line else { return }
            self.model.showBasicLine(line)
        }
        views.add(ScrolledWindow(list.margin(16), horizontal: GTK_POLICY_NEVER).expand(), name: "calls")
        views.add(EmptyState("Stop in the program (a breakpoint, a step, or Pause in BASIC) to see its PROC and FN calls."),
                  name: "empty")
        root = views
        root.track { [unowned self] in self.update() }
        root.keep(self)
    }

    private func update() {
        let frames = model.basic?.frames ?? []
        views.visible = frames.isEmpty ? "empty" : "calls"
        guard frames != self.frames else { return }
        self.frames = frames
        list.removeAll()
        for (index, frame) in frames.enumerated() {
            let title = frame.name.map { $0 == "?" ? "(not followed further)" : $0 } ?? "Main program"
            let subtitle = frame.location.map { (index == 0 ? "at " : "called at ") + "\($0)" } ?? "from a command typed in"
            let row = PlainActionRow(title, subtitle: subtitle)
            row.style("debugger-code-title")
            if index == 0 { row.style("debugger-current-frame") }
            if frame.location != nil {
                gtk_list_box_row_set_activatable(cast(row.widget), 1)
                row.tooltip("Show the line")
                row.suffix(Icon("go-next-symbolic").style("dim-label"))
            }
            list.append(row)
        }
    }
}

// MARK: Breakpoints

@MainActor
final class BasicBreakpointsTab {
    let model: DebuggerModel
    private(set) var root: Widget!
    private let errorStop = ToggleGroup(["Off", "Untrapped", "All"]) { _ in }
    private let list = ListBox()
    private let line = PlainEntryRow("Line (e.g. 120)")
    private let statement = PlainEntryRow("Statement (optional: 1 is the first)")
    private let condition = PlainEntryRow("Condition (BASIC, e.g. I%>10)")
    private let logMessage = PlainEntryRow("Log (log instead of stopping: I%={I%})")
    private let addButton = Button("Add Breakpoint")
    private let removeAll = Button("Remove All")

    private struct Row {
        let row: ActionRow
        let toggle: Switch
        let hits: Label
    }

    private var rows: [Int: Row] = [:]
    private var ids: [Int] = []
    private var breakpoints: [BasicBreakpoint] = []
    private var detailsKey: [String] = []
    private var updating = false
    private static let modes: [BasicDebugger.ErrorStop] = [.off, .untrapped, .all]

    init(model: DebuggerModel) {
        self.model = model
        build()
    }

    private func build() {
        errorStop.align(vertical: GTK_ALIGN_CENTER)
        errorStop.object.onChange("active") { [unowned self] in
            guard !self.updating else { return }
            let index = self.errorStop.selected
            if Self.modes.indices.contains(index) { self.model.setBasicErrorStop(Self.modes[index]) }
        }
        let errors = PlainActionRow("Stop on errors")
        errors.suffix(errorStop)
        errors.tooltip("Stop where an error happens: those no ON ERROR handles (Escape and STOP too), or all of them")
        list.style("boxed-list")
        list.placeholder(Label("No breakpoints", style: "dim-label").margin(12).centred())
        list.onActivate { [unowned self] index in
            guard self.breakpoints.indices.contains(index) else { return }
            self.model.showBasicLine(self.breakpoints[index].line)
        }
        for row in [line, statement, condition, logMessage] {
            row.object.on("entry-activated") { [unowned self] in self.add() }
            row.style("debugger-code-entry")
        }
        line.object.on("changed") { [unowned self] in self.updateAddButton() }
        addButton.onClicked { [unowned self] in self.add() }
        addButton.style("suggested-action")
        updateAddButton()
        removeAll.onClicked { [unowned self] in self.model.removeAllBasicBreakpoints() }
        removeAll.style("destructive-action")
        let content = Box(.vertical, spacing: 18) {
            PreferencesGroup { errors }
            list
            PreferencesGroup {
                line
                statement
                condition
                logMessage
            }
            Box(.horizontal, spacing: 12) {
                addButton
                HSpacer()
                removeAll
            }
        }
        .margin(16)
        root = ScrolledWindow(content, horizontal: GTK_POLICY_NEVER).expand()
        root.track { [unowned self] in self.update() }
        root.keep(self)
    }

    private func updateAddButton() {
        addButton.isEnabled = Int(line.text.trimmingCharacters(in: .whitespaces)) != nil
    }

    private func update() {
        let basic = model.basic
        updating = true
        defer { updating = false }
        errorStop.selected = Self.modes.firstIndex(of: basic?.errorStop ?? .off) ?? 0
        let breakpoints = basic?.breakpoints ?? []
        removeAll.isEnabled = !breakpoints.isEmpty
        let details = breakpoints.map { detail($0) ?? "" }
        guard breakpoints != self.breakpoints || details != detailsKey else { return }
        self.breakpoints = breakpoints
        detailsKey = details
        let ids = breakpoints.map(\.id)
        if ids != self.ids {
            self.ids = ids
            list.removeAll()
            rows = [:]
            for b in breakpoints {
                let id = b.id
                let row = PlainActionRow(Self.title(b))
                row.style("debugger-code-title")
                gtk_list_box_row_set_activatable(cast(row.widget), 1)
                row.tooltip("Show the line")
                let toggle = Switch(isOn: b.enabled) { [unowned self] on in self.setEnabled(id, on) }
                toggle.tooltip("Enabled")
                let hits = Label("\(b.hitCount)", style: "dim-label", "caption", "numeric")
                hits.tooltip("Hits")
                let remove = IconButton("list-remove-symbolic", "Remove the breakpoint", label: "Remove") {
                    [unowned self] in self.model.removeBasicBreakpoint(id: id)
                }
                remove.align(vertical: GTK_ALIGN_CENTER).style("circular")
                row.prefix(toggle).suffix(hits).suffix(remove)
                list.append(row)
                rows[id] = Row(row: row, toggle: toggle, hits: hits)
            }
        }
        for (b, detail) in zip(breakpoints, details) {
            guard let row = rows[b.id] else { continue }
            row.row.title = Self.title(b)
            row.row.subtitle = detail
            row.toggle.isOn = b.enabled
            row.hits.text = "\(b.hitCount)"
        }
    }

    private func setEnabled(_ id: Int, _ on: Bool) {
        guard !updating, var changed = breakpoints.first(where: { $0.id == id }) else { return }
        changed.enabled = on
        model.updateBasicBreakpoint(changed)
    }

    private func add() {
        guard let number = Int(line.text.trimmingCharacters(in: .whitespaces)) else {
            gtk_widget_error_bell(line.widget)
            return
        }
        model.addBasicBreakpoint(BasicBreakpoint(line: number, statement: Int(statement.text.trimmingCharacters(in: .whitespaces)),
                                                 condition: condition.text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : condition.text,
                                                 logMessage: logMessage.text.isEmpty ? nil : logMessage.text))
        line.text = ""
        statement.text = ""
        condition.text = ""
        logMessage.text = ""
    }

    static func title(_ b: BasicBreakpoint) -> String {
        "Line \(b.line)" + (b.statement.map { " statement \($0)" } ?? "")
    }

    private func detail(_ b: BasicBreakpoint) -> String? {
        var parts: [String] = []
        if let c = b.condition { parts.append("if \(c)") }
        if let l = b.logMessage { parts.append("log \(l)") }
        if let h = b.hitTarget { parts.append("from hit \(h)") }
        if model.basic?.lines.isEmpty == false && !(model.basic?.lines.contains { $0.number == b.line } ?? true) {
            parts.append("no such line")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

// MARK: Watch

@MainActor
final class BasicWatchTab {
    let model: DebuggerModel
    private(set) var root: Widget!
    private let expression = Entry(placeholder: "e.g. total/count%")
    private let list = ListBox()
    private let views = Stack()

    private struct Row {
        let value: Label
        let error: Label
    }

    private var rows: [String: Row] = [:]
    private var expressions: [String] = []

    init(model: DebuggerModel) {
        self.model = model
        build()
    }

    private func build() {
        expression.style("debugger-code").expand(horizontal: true).accessibleLabel("Expression")
        expression.onActivate { [unowned self] in self.add() }
        let header = Box(.horizontal, spacing: 6) {
            expression
            Button("Watch") { [unowned self] in self.add() }
        }
        .margin(horizontal: 16, vertical: 10)
        list.style("boxed-list").align(vertical: GTK_ALIGN_START)
        views.add(ScrolledWindow(list.margin(16), horizontal: GTK_POLICY_NEVER).expand(), name: "watches")
        views.add(EmptyState("Watch BASIC expressions: variables, array elements, arithmetic and comparisons. They update as the program runs."),
                  name: "empty")
        root = Box(.vertical) {
            header
            Separator()
            views.expand()
        }
        root.track { [unowned self] in self.update() }
        root.keep(self)
    }

    private func add() {
        model.addBasicWatch(expression.text)
        expression.text = ""
    }

    private func update() {
        // (The expressions as asked for, before a snapshot has their values.)
        let watches = model.basic?.watches ?? []
        let expressions = watches.map(\.expression)
        views.visible = expressions.isEmpty ? "empty" : "watches"
        if expressions != self.expressions {
            self.expressions = expressions
            list.removeAll()
            rows = [:]
            for watch in watches {
                let text = watch.expression
                let row = PlainActionRow(text)
                row.style("debugger-code-title")
                let value = Label("", style: "debugger-code-small", "dim-label")
                value.ellipsize().maxWidthChars(18).xalign(1)
                let error = Label("", style: "error", "caption")
                error.wrap().lines(2).ellipsize().maxWidthChars(22).xalign(1)
                let remove = IconButton("list-remove-symbolic", "Stop watching it", label: "Remove") {
                    [unowned self] in self.model.removeBasicWatch(text)
                }
                remove.align(vertical: GTK_ALIGN_CENTER).style("circular")
                row.suffix(value).suffix(error).suffix(remove)
                list.append(row)
                rows[text] = Row(value: value, error: error)
            }
        }
        for watch in watches {
            guard let row = rows[watch.expression] else { continue }
            switch watch.result {
            case .success(let value):
                // (The tooltip too: the value may be cut short.)
                if row.value.text != value.description {
                    row.value.text = value.description
                    row.value.tooltip(value.description)
                }
                row.value.isVisible = true
                row.error.isVisible = false
            case .failure(let error):
                if row.error.text != error.message {
                    row.error.text = error.message
                    row.error.tooltip(error.message)
                }
                row.error.isVisible = true
                row.value.isVisible = false
            }
        }
    }
}
