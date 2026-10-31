import BeebCore
import BeebHost
import CGtk
import Foundation

// The machine code view's sidebar: the CPU's registers, flags and stack,
// breakpoints, the hardware's state, the trace, the profile and the log.
// (The Mac's DebuggerSidebar and its views.)

/// Tabs down a sidebar (the Mac's segmented picker over a switch), the one
/// shown remembered under `defaultsKey` by the Mac's names.
@MainActor
func SidebarTabs(defaultsKey: String, initial: String, _ tabs: [(name: String, icon: String, content: Widget)]) -> Widget {
    let stack = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    let names = tabs.map(\.name)
    for tab in tabs {
        stack.add(tab.content, name: tab.name, title: tab.name)
    }
    let saved = UserDefaults.standard.string(forKey: defaultsKey)
    let shown = names.firstIndex { $0 == saved } ?? names.firstIndex(of: initial) ?? 0
    stack.visible = names[shown]
    let switcher = ToggleGroup(names, selected: shown) { index in
        guard names.indices.contains(index) else { return }
        stack.visible = names[index]
        UserDefaults.standard.set(names[index], forKey: defaultsKey)
    }
    switcher.homogeneous(false).style("debugger-tabs")
    GObjectRef(switcher.widget).set("can-shrink", false)
    switcher.accessibleLabel("Sidebar")
    switcher.align(horizontal: GTK_ALIGN_CENTER).margin(top: 6, bottom: 6, start: 8, end: 8)
    return Box(.vertical) {
        switcher
        Separator()
        stack.expand()
    }
}

@MainActor
enum MachineSidebar {
    static func make(model: DebuggerModel) -> Widget {
        SidebarTabs(defaultsKey: "MacBeebDebuggerTab", initial: "CPU", [
            ("CPU", "cpu-symbolic", RegistersTab(model: model).root),
            ("Breakpoints", "media-record-symbolic", BreakpointsTab(model: model).root),
            ("Hardware", "computer-symbolic", HardwareTab(model: model).root),
            ("Trace", "view-list-symbolic", TraceTab(model: model).root),
            ("Profile", "speedometer-symbolic", ProfileTab(model: model).root),
            ("Log", "utilities-terminal-symbolic", LogTab(model: model).root),
        ])
    }
}

// MARK: CPU

/// The registers (editable while stopped), the flags (set and cleared by
/// a click), the cycle and the stack. (The Mac's RegistersView.)
@MainActor
final class RegistersTab {
    let model: DebuggerModel
    private(set) var root: Widget!
    private let registers = Grid(rowSpacing: 6, columnSpacing: 10)
    private let flags = Grid(rowSpacing: 6, columnSpacing: 6)
    private let midInstruction = Box(.horizontal, spacing: 6)
    private let cycle = Label("", style: "dim-label", "numeric")
    private let stack = Label("", style: "debugger-code-small")
    private let stackHeading = Label("Stack", style: "heading")
    private let empty = EmptyState("The registers show when the machine's running.")
    private let views = Stack()
    private var stackMarkup = ""

    private struct RegisterRow {
        let entry: Entry
        let decimal: Label
        var value: Int
        let digits: Int
        var focused = false
    }

    private var rows: [String: RegisterRow] = [:]
    private var layout: [String] = []
    private var flagButtons: [ToggleButton] = []
    private var flagState: [DebugFlag] = []
    private var updatingFlags = false
    private var flagsStopped: Bool?
    private var stopped = false

    init(model: DebuggerModel) {
        self.model = model
        build()
    }

    private func build() {
        gtk_grid_set_column_homogeneous(cast(flags.widget), 1)
        registers.align(horizontal: GTK_ALIGN_START)
        midInstruction.append(Icon("dialog-information-symbolic"))
        midInstruction.append(Label("Mid-instruction: step to finish it").wrap())
        midInstruction.style("dim-label")
        stack.selectable().align(horizontal: GTK_ALIGN_START)
        let content = Box(.vertical, spacing: 12) {
            registers
            flags
            midInstruction
            cycle
            Separator().margin(vertical: 4)
            stackHeading
            stack
        }
        .margin(16)
        views.add(ScrolledWindow(content, horizontal: GTK_POLICY_NEVER).expand(), name: "registers")
        views.add(empty, name: "empty")
        root = views
        root.track { [unowned self] in self.update() }
        root.keep(self)
    }

    private func update() {
        let stopped = model.isStopped
        guard let state = model.snapshot?.state(model.cpu) else {
            views.visible = "empty"
            return
        }
        views.visible = "registers"
        let names = state.registers.map(\.name)
        if names != layout {
            rebuildRegisters(state.registers)
        }
        for register in state.registers {
            guard var row = rows[register.name] else { continue }
            if register.value != row.value || stopped != self.stopped {
                row.value = register.value
                if !row.focused { row.entry.text = "&" + hex(register.value, row.digits) }
                row.decimal.text = "\(register.value)"
            }
            row.entry.isEnabled = stopped
            rows[register.name] = row
        }
        self.stopped = stopped
        updateFlags(state.flags, stopped: stopped)
        midInstruction.isVisible = !state.atInstruction
        cycle.text = "Cycle \(model.snapshot?.cycles ?? 0)"
        let entries = model.snapshot?.stack ?? []
        let markup = entries.map { "<span alpha=\"55%\">\(hex($0.address, 4))</span>  \(hex($0.value))" }
            .joined(separator: "\n")
        // (Only when it changes: setting it clears a selection.)
        if markup != stackMarkup {
            stackMarkup = markup
            stack.markup = markup
        }
        stack.isVisible = !entries.isEmpty
        stackHeading.isVisible = !entries.isEmpty
    }

    private func rebuildRegisters(_ registers: [DebugRegister]) {
        self.registers.removeAll()
        rows = [:]
        layout = registers.map(\.name)
        for (index, register) in registers.enumerated() {
            let name = register.name
            let entry = Entry(text: "&" + hex(register.value, register.digits))
            entry.widthChars(register.digits == 4 ? 6 : 4).style("debugger-code", "debugger-register")
            gtk_editable_set_max_width_chars(cast(entry.widget), register.digits == 4 ? 6 : 4)
            entry.accessibleLabel(name)
            entry.onActivate { [unowned self] in self.commit(name) }
            entry.add(FocusController()
                .onEnter { [unowned self] in self.rows[name]?.focused = true }
                .onLeave { [unowned self] in
                    guard var row = self.rows[name] else { return }
                    row.focused = false
                    row.entry.text = "&" + hex(row.value, row.digits)
                    self.rows[name] = row
                })
            let decimal = Label("\(register.value)", style: "debugger-code-small", "dim-label")
            let label = Label(name, style: "debugger-code", "dim-label")
            self.registers.attach(label, column: 0, row: Int32(index))
            self.registers.attach(entry, column: 1, row: Int32(index))
            self.registers.attach(decimal, column: 2, row: Int32(index))
            rows[name] = RegisterRow(entry: entry, decimal: decimal, value: register.value, digits: register.digits)
        }
    }

    private func commit(_ name: String) {
        guard let row = rows[name] else { return }
        if let value = parseHex(row.entry.text) {
            model.setRegister(name, to: value)
        } else {
            row.entry.text = "&" + hex(row.value, row.digits)
            gtk_widget_error_bell(row.entry.widget)
        }
    }

    private func updateFlags(_ flags: [DebugFlag], stopped: Bool) {
        updatingFlags = true
        defer { updatingFlags = false }
        var changed = stopped != flagsStopped
        flagsStopped = stopped
        if flags.map(\.label) != flagState.map(\.label) {
            changed = true
            self.flags.removeAll()
            flagButtons = []
            for (index, flag) in flags.enumerated() {
                let button = ToggleButton(flag.label, isOn: flag.set) { [unowned self] _ in self.toggle(index) }
                button.style("debugger-flag", "debugger-code")
                // A Z80's flags and flip-flops wrap onto a second row.
                self.flags.attach(button, column: Int32(index % 8), row: Int32(index / 8))
                flagButtons.append(button)
            }
        }
        guard changed || flags != flagState else { return }
        flagState = flags
        for (button, flag) in zip(flagButtons, flags) {
            button.isOn = flag.set
            button.isEnabled = stopped && flag.register != nil
            button.tooltip(flag.register == nil ? nil : (flag.set ? "Set: click to clear it" : "Clear: click to set it"))
        }
    }

    private func toggle(_ index: Int) {
        guard !updatingFlags, flagState.indices.contains(index) else { return }
        let flag = flagState[index]
        // (It shows the machine's state until that changes.)
        updatingFlags = true
        flagButtons[index].isOn = flag.set
        updatingFlags = false
        if let name = flag.register { model.setRegister(name, to: flag.set ? 0 : 1) }
    }
}

// MARK: Breakpoints

@MainActor
final class BreakpointsTab {
    let model: DebuggerModel
    private(set) var root: Widget!
    private let list = ListBox()
    private let address = PlainEntryRow("Address (&1900 or expression)")
    private let end = PlainEntryRow("To (optional end of range)")
    private let kind = ComboRow("Stop on", items: ["Execute", "Read", "Write", "Read or write"])
    private let condition = PlainEntryRow("Condition (e.g. A == &41)")
    private let logMessage = PlainEntryRow("Log (log instead of stopping: A={A})")
    private let removeAll = Button("Remove All")
    private let addButton = Button("Add Breakpoint")

    private struct Row {
        let row: ActionRow
        let toggle: Switch
        let hits: Label
    }

    private var rows: [Int: Row] = [:]
    private var ids: [Int] = []
    private var breakpoints: [Breakpoint] = []
    private var updating = false

    init(model: DebuggerModel) {
        self.model = model
        build()
    }

    private func build() {
        list.style("boxed-list")
        list.placeholder(Label("No breakpoints", style: "dim-label").margin(12).centred())
        for row in [address, end, condition, logMessage] {
            row.object.on("entry-activated") { [unowned self] in self.add() }
            row.style("debugger-code-entry")
        }
        address.object.on("changed") { [unowned self] in
            self.address.removeStyle("error")
            self.addButton.isEnabled = !self.address.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let form = PreferencesGroup {
            address
            end
            kind
            condition
            logMessage
        }
        addButton.onClicked { [unowned self] in self.add() }
        addButton.style("suggested-action").enabled(false)
        removeAll.onClicked { [unowned self] in self.model.removeAllBreakpoints() }
        removeAll.style("destructive-action")
        let content = Box(.vertical, spacing: 18) {
            list
            form
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

    private func update() {
        let breakpoints = model.snapshot?.breakpoints ?? []
        removeAll.isEnabled = !breakpoints.isEmpty
        guard breakpoints != self.breakpoints else { return }
        self.breakpoints = breakpoints
        updating = true
        defer { updating = false }
        let ids = breakpoints.map(\.id)
        if ids != self.ids {
            self.ids = ids
            list.removeAll()
            rows = [:]
            for b in breakpoints {
                let id = b.id
                let row = PlainActionRow(Self.title(b))
                row.style("debugger-code-title")
                let toggle = Switch(isOn: b.enabled) { [unowned self] on in self.setEnabled(id, on) }
                toggle.tooltip("Enabled")
                let hits = Label("\(b.hitCount)", style: "dim-label", "caption", "numeric")
                hits.tooltip("Hits")
                let remove = IconButton("list-remove-symbolic", "Remove the breakpoint", label: "Remove") {
                    [unowned self] in self.model.removeBreakpoint(id: id)
                }
                remove.align(vertical: GTK_ALIGN_CENTER).style("circular")
                row.prefix(toggle).suffix(hits).suffix(remove)
                list.append(row)
                rows[id] = Row(row: row, toggle: toggle, hits: hits)
            }
        }
        for b in breakpoints {
            guard let row = rows[b.id] else { continue }
            row.row.title = Self.title(b)
            row.row.subtitle = Self.detail(b) ?? ""
            row.toggle.isOn = b.enabled
            row.hits.text = "\(b.hitCount)"
        }
    }

    private func setEnabled(_ id: Int, _ on: Bool) {
        guard !updating, var changed = breakpoints.first(where: { $0.id == id }) else { return }
        changed.enabled = on
        model.updateBreakpoint(changed)
    }

    private func add() {
        let (text, endText) = (address.text, end.text)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let kinds: [Breakpoint.Kind] = [.execute, .read, .write, .access]
        let breakpointKind = kinds.indices.contains(kind.selected) ? kinds[kind.selected] : .execute
        let cpu = model.cpu
        let condition = self.condition.text.isEmpty ? nil : self.condition.text
        let log = logMessage.text.isEmpty ? nil : logMessage.text
        Task {
            guard let start = await model.address(text) else {
                model.message = "Bad address: \(text)"
                address.style("error")
                gtk_widget_error_bell(address.widget)
                return
            }
            let last = endText.isEmpty ? start : (await model.address(endText) ?? start)
            model.addBreakpoint(Breakpoint(cpu: cpu, kind: breakpointKind, start: UInt16(truncatingIfNeeded: start),
                                           end: UInt16(truncatingIfNeeded: last), condition: condition, logMessage: log))
            address.text = ""
            end.text = ""
        }
    }

    static func title(_ b: Breakpoint) -> String {
        let kind = b.kind == .execute ? "exec" : b.kind == .read ? "read" : b.kind == .write ? "write" : "r/w"
        let range = "&" + hex(b.start, 4) + (b.end != b.start ? "-&" + hex(b.end, 4) : "")
        return "\(kind) \(range)" + (b.cpu == .parasite ? " (2P)" : "")
    }

    static func detail(_ b: Breakpoint) -> String? {
        var parts: [String] = []
        if let c = b.condition { parts.append("if \(c)") }
        if let l = b.logMessage { parts.append("log \(l)") }
        if let h = b.hitTarget { parts.append("from hit \(h)") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

// MARK: Hardware

/// The devices' state, section by section. (The Mac's HardwareView.)
@MainActor
final class HardwareTab {
    let model: DebuggerModel
    private(set) var root: Widget!
    private let content = Box(.vertical, spacing: 18)
    private var layout: [[String]] = []
    private var names: [String] = []
    private var values: [[Label]] = []

    init(model: DebuggerModel) {
        self.model = model
        content.margin(16)
        root = ScrolledWindow(content, horizontal: GTK_POLICY_NEVER).expand()
        root.track { [unowned self] in self.update() }
        root.keep(self)
    }

    private func update() {
        let sections = model.snapshot?.hardware ?? []
        let layout = sections.map { $0.rows.map(\.label) }
        if layout != self.layout || sections.map(\.name) != names {
            self.layout = layout
            names = sections.map(\.name)
            content.removeAll()
            values = []
            for section in sections {
                let list = ListBox().style("boxed-list")
                var labels: [Label] = []
                for row in section.rows {
                    let value = Label(row.value, style: "debugger-code-small")
                    value.xalign(1).justify(GTK_JUSTIFY_RIGHT).wrap().selectable()
                    value.expand(horizontal: true)
                    let line = Box(.horizontal, spacing: 12) {
                        Label(row.label, style: "dim-label").align(vertical: GTK_ALIGN_BASELINE_FILL)
                        value
                    }
                    .margin(horizontal: 12, vertical: 7)
                    list.append(ListRow(line))
                    labels.append(value)
                }
                values.append(labels)
                content.append(Box(.vertical, spacing: 8) {
                    Label(section.name, style: "heading").margin(start: 2)
                    list
                })
            }
        }
        for (section, labels) in zip(sections, values) {
            for (row, label) in zip(section.rows, labels) {
                label.text = row.value
            }
        }
    }
}

// MARK: Trace

/// The last instructions run, recorded as they run. (The Mac's TraceView.)
@MainActor
final class TraceTab {
    let model: DebuggerModel
    private(set) var root: Widget!
    private let canvas: CodeCanvas
    private let metrics: TextMetrics
    private let record = Switch()
    private let views = Stack()
    private let empty = EmptyState("")
    private var trace: [DebugSnapshot.TraceLine] = []
    private var updating = false

    init(model: DebuggerModel) {
        self.model = model
        metrics = TextMetrics(CodeFont.small, widget: Label())
        canvas = CodeCanvas(rowHeight: metrics.lineHeight + 4)
        build()
    }

    private func build() {
        record.object.onChange("active") { [unowned self] in
            guard !self.updating else { return }
            self.model.setTracing(self.record.isOn)
        }
        record.accessibleLabel("Record the last 100,000 instructions")
        let title = Label("Record the last 100,000 instructions").wrap().expand(horizontal: true)
        let header = Box(.horizontal, spacing: 12) {
            title
            record
        }
        .margin(horizontal: 16, vertical: 10)
        canvas.drawRow = { [unowned self] painter, palette, row, y, width in
            self.draw(row, painter, palette, y, width)
        }
        canvas.area.accessibleLabel("Trace")
        canvas.scroller.style("debugger-view")
        views.add(canvas.widget, name: "trace")
        views.add(empty, name: "empty")
        root = Box(.vertical) {
            header
            Separator()
            views.expand()
        }
        root.track { [unowned self] in self.update() }
        root.keep(self)
    }

    private func update() {
        let tracing = model.snapshot?.tracing ?? false
        updating = true
        record.isOn = tracing
        updating = false
        let trace = model.snapshot?.trace ?? []
        views.visible = trace.isEmpty ? "empty" : "trace"
        empty.text = tracing ? "Instructions show here as the machine runs."
            : "Turn on recording to list the instructions as they run, and to step back through them."
        guard trace != self.trace else { return }
        let moved = trace.last?.entry.cycle != self.trace.last?.entry.cycle
        self.trace = trace
        canvas.setRows(trace.count)
        if moved { canvas.scrollToEnd() }
    }

    private func draw(_ row: Int, _ painter: TextPainter, _ palette: Palette, _ y: Double, _ width: Double) {
        let line = trace[row]
        let textY = y + (canvas.rowHeight - metrics.lineHeight) / 2
        let x = 16.0
        painter.text(hex(line.entry.pc, 4), x: x, y: textY, font: CodeFont.small, color: palette.secondary)
        let textX = x + 4 * metrics.charWidth + 8
        let registersX = textX + max(130, 16 * metrics.charWidth) + 8
        painter.text(line.text, x: textX, y: textY, font: CodeFont.small, color: palette.foreground,
                     width: registersX - textX - 8)
        painter.text(line.entry.registerText, x: registersX, y: textY, font: CodeFont.small, color: palette.secondary,
                     width: width - registersX - 8)
    }
}

// MARK: Profile

/// Where the time goes: routines and the busiest instructions, by cycles.
/// (The Mac's ProfileView.)
@MainActor
final class ProfileTab {
    let model: DebuggerModel
    private(set) var root: Widget!
    private let canvas: CodeCanvas
    private let metrics: TextMetrics
    private let toggle = Button("Start Profiling")
    private let summary = Label("", style: "dim-label", "caption")
    private let views = Stack()

    private enum Row {
        case heading(String)
        case entry(name: String, cycles: Int)
    }

    private var rows: [Row] = []
    private var total = 1
    private var shown: (Int, Int, Int)?

    init(model: DebuggerModel) {
        self.model = model
        metrics = TextMetrics(CodeFont.small, widget: Label())
        canvas = CodeCanvas(rowHeight: metrics.lineHeight + 6)
        build()
    }

    private func build() {
        toggle.onClicked { [unowned self] in
            self.model.setProfiling(!(self.model.snapshot?.isProfiling ?? false))
        }
        summary.wrap().xalign(1).expand(horizontal: true)
        let header = Box(.horizontal, spacing: 12) {
            toggle
            summary
        }
        .margin(horizontal: 16, vertical: 10)
        canvas.drawRow = { [unowned self] painter, palette, row, y, width in
            self.draw(row, painter, palette, y, width)
        }
        canvas.area.accessibleLabel("Profile")
        canvas.scroller.style("debugger-view")
        views.add(canvas.widget, name: "profile")
        views.add(EmptyState("Start profiling to count the cycles spent at every address. The disassembly shows where the time goes; routines are grouped by symbol."),
                  name: "empty")
        root = Box(.vertical) {
            header
            Separator()
            views.expand()
        }
        root.track { [unowned self] in self.update() }
        root.keep(self)
    }

    private func update() {
        let profiling = model.snapshot?.isProfiling == true
        let label = profiling ? "Stop Profiling" : "Start Profiling"
        if toggle.label != label { toggle.label = label }
        guard let profile = model.snapshot?.profile, profile.totalCycles > 0 else {
            summary.isVisible = model.snapshot?.profile != nil
            summary.text = model.snapshot?.profile.map(Self.summary) ?? ""
            views.visible = "empty"
            return
        }
        summary.isVisible = true
        summary.text = Self.summary(profile)
        views.visible = "profile"
        // (Redrawn when the numbers change.)
        let key = (profile.totalCycles, profile.frames, profile.hottest.first?.cycles ?? 0)
        if let shown, shown == key { return }
        shown = key
        total = profile.totalCycles
        rows = [.heading("Routines")]
        rows += profile.routines.prefix(30).map { .entry(name: $0.name, cycles: $0.cycles) }
        rows.append(.heading("Busiest instructions"))
        rows += profile.hottest.map { .entry(name: "&" + hex($0.address, 4) + "  ×\($0.executions)", cycles: $0.cycles) }
        canvas.setRows(rows.count)
        canvas.redraw()
    }

    static func summary(_ p: ProfileReport) -> String {
        let interrupts = p.totalCycles > 0 ? Double(p.interruptCycles) * 100 / Double(p.totalCycles) : 0
        return String(format: "%d frames, %.0f cycles/frame, %.1f%% in interrupts", p.frames, p.cyclesPerFrame, interrupts)
    }

    private func draw(_ row: Int, _ painter: TextPainter, _ palette: Palette, _ y: Double, _ width: Double) {
        let cairo = painter.cairo
        let x = 16.0
        switch rows[row] {
        case .heading(let title):
            painter.text(title, x: x, y: y + canvas.rowHeight - metrics.lineHeight - 1, font: CodeFont.heading,
                         color: palette.secondary)
        case .entry(let name, let cycles):
            let textY = y + (canvas.rowHeight - metrics.lineHeight) / 2
            let share = Double(cycles) / Double(max(total, 1))
            let percentRight = x + 7 * metrics.charWidth
            painter.text(String(format: "%5.1f%%", share * 100), right: percentRight, y: textY, font: CodeFont.small,
                         color: palette.foreground)
            let barX = percentRight + 10, barY = y + canvas.rowHeight / 2 - 3
            cairo.color(palette.heat, alpha: 0.15)
            cairo.roundedRectangle(barX, barY, 60, 6, radius: 3)
            cairo.fill()
            if share > 0 {
                cairo.color(palette.heat, alpha: 0.75)
                cairo.roundedRectangle(barX, barY, max(2, 60 * share), 6, radius: 3)
                cairo.fill()
            }
            let nameX = barX + 60 + 10
            painter.text(name, x: nameX, y: textY, font: CodeFont.small, color: palette.foreground, width: width - nameX - 8)
        }
    }
}

// MARK: Log

/// Log points' output. (The Mac's LogView; the BASIC view's too.)
@MainActor
final class LogTab {
    let model: DebuggerModel
    private(set) var root: Widget!
    private let canvas: CodeCanvas
    private let code: TextMetrics
    private let caption: TextMetrics
    private let views = Stack()
    private var log: [DebugLogEntry] = []

    init(model: DebuggerModel) {
        self.model = model
        let probe = Label()
        code = TextMetrics(CodeFont.small, widget: probe)
        caption = TextMetrics(CodeFont.caption, widget: probe)
        canvas = CodeCanvas(rowHeight: code.lineHeight + caption.lineHeight + 10)
        build()
    }

    private func build() {
        canvas.drawRow = { [unowned self] painter, palette, row, y, width in
            let entry = self.log[row]
            let x = 16.0
            painter.text(entry.text, x: x, y: y + 4, font: CodeFont.small, color: palette.foreground, width: width - x - 8)
            painter.text("\(entry.cpu == .host ? "host" : "2P"), cycle \(entry.cycle)", x: x, y: y + 4 + self.code.lineHeight,
                         font: CodeFont.caption, color: palette.secondary, width: width - x - 8)
            if row < self.log.count - 1 {
                painter.cairo.color(palette.faint, alpha: 0.5)
                painter.cairo.rectangle(x, y + self.canvas.rowHeight - 1, width - x, 1)
                painter.cairo.fill()
            }
        }
        canvas.area.accessibleLabel("Log")
        canvas.scroller.style("debugger-view")
        views.add(canvas.widget, name: "log")
        views.add(EmptyState("Log points' output appears here. Add a breakpoint with a log message to log instead of stopping."),
                  name: "empty")
        root = views
        root.track { [unowned self] in self.update() }
        root.keep(self)
    }

    private func update() {
        let log = model.snapshot?.log ?? []
        views.visible = log.isEmpty ? "empty" : "log"
        guard log != self.log else { return }
        let follow = canvas.isAtEnd
        self.log = log
        canvas.setRows(log.count)
        if follow { canvas.scrollToEnd() }
    }
}
