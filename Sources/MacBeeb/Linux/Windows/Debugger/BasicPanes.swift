import BeebCore
import BeebHost
import CGtk
import Foundation

// The debugger's BASIC view: the program, with breakpoints in its gutter,
// and its variables. (The Mac's BasicListingView and BasicVariablesView.)

// MARK: Listing

@MainActor
final class BasicListingPane {
    let model: DebuggerModel
    private(set) var root: Widget!
    let goTo = Entry(placeholder: "Go to line")
    private let current = Button("Current")
    private let interpreter = Label("", style: "dim-label")
    private let errorBar = Box(.horizontal, spacing: 8)
    private let errorText = Label()
    private let views = Stack()
    private let noROM = StatusPage(icon: "action-unavailable-symbolic", title: "No BASIC ROM found",
                                   description: "Select BASIC (*BASIC) to debug a BASIC program.").compact()
    private let noProgram = StatusPage(icon: "document-edit-symbolic", title: "No program in memory",
                                       description: "Type a program in, or LOAD one. Breakpoints set in the Breakpoints tab wait for their lines.").compact()
    private let message = Label("", style: "debugger-message")
    private let canvas: CodeCanvas
    private let metrics: TextMetrics

    private var lines: [BasicDebugSnapshot.Line] = []
    private var stop: BasicLocation?
    private var isError = false
    private var stopped = false
    private var numberWidth = 1
    private var scrolledStop: BasicLocation??
    private var scrollRequest: DebuggerModel.ScrollRequest?

    private let menu = Menu {}
    private var contextMenu: Popover!
    private var contextLine: Int?
    private let editorHolder = Bin()
    private var editor: Popover!

    init(model: DebuggerModel) {
        self.model = model
        metrics = TextMetrics(CodeFont.code, widget: Label())
        canvas = CodeCanvas(rowHeight: metrics.lineHeight + 3)
        build()
    }

    private func build() {
        goTo.widthChars(10).style("debugger-code").tooltip("A line number (Ctrl+L)")
        goTo.onActivate { [unowned self] in
            if let line = Int(self.goTo.text.trimmingCharacters(in: .whitespaces)) {
                self.model.showBasicLine(line)
            } else {
                gtk_widget_error_bell(self.goTo.widget)
            }
        }
        current.tooltip("Show the line it's stopped at").style("flat")
        current.onClicked { [unowned self] in
            if let line = self.model.basic?.stop?.line { self.model.showBasicLine(line) }
        }
        interpreter.ellipsize().margin(start: 6)
        let header = PaneHeader("BASIC") {
            interpreter
            HSpacer()
            goTo
            current
        }
        errorText.wrap().expand(horizontal: true)
        errorBar.append(Icon("dialog-error-symbolic").align(vertical: GTK_ALIGN_START))
        errorBar.append(errorText)
        errorBar.margin(horizontal: 12, vertical: 8)
        let errorWrapper = Box(.vertical) { errorBar; Separator() }.style("debugger-error-bar")
        errorWrapper.visible(false)
        self.errorWrapper = errorWrapper
        message.wrap().margin(horizontal: 12, vertical: 6).visible(false)

        canvas.drawRow = { [unowned self] painter, palette, row, y, width in
            self.draw(row, painter, palette, y, width)
        }
        canvas.onPress = { [unowned self] row, x, y, presses, button, modifiers in
            guard row >= 0, presses == 1 else { return }
            let control = modifiers.rawValue & GDK_CONTROL_MASK.rawValue != 0
            if button == 3 || (button == 1 && control) {
                self.showContextMenu(row, x: x, y: y)
            } else if button == 1 && x < self.gutterEnd {
                self.model.toggleBasicBreakpoint(line: self.lines[row].number)
            }
        }
        canvas.tooltip = { [unowned self] row, x in
            guard x < self.gutterEnd else { return nil }
            return self.lines[row].breakpoints.isEmpty ? "Stop at this line (right-click for a condition)"
                : "Remove the breakpoint (right-click to edit it)"
        }
        canvas.cursor = { [unowned self] row, x in row >= 0 && x < self.gutterEnd ? "pointer" : nil }
        canvas.area.accessibleLabel("BASIC program")
        canvas.scroller.style("debugger-view")
        // A long press on a touchscreen, as a right-click.
        let press = EventController(gtk_gesture_long_press_new())
        press.object.onPoint("pressed") { [unowned self] x, y in
            let row = self.canvas.row(at: y)
            if row >= 0 { self.showContextMenu(row, x: x, y: y) }
        }
        canvas.area.add(press)

        // The context menu's commands.
        let actions = g_simple_action_group_new()!
        for action in [
            Action("edit-breakpoint") { [unowned self] in self.editContextLine() },
            Action("remove-breakpoint") { [unowned self] in
                if let line = self.contextLine { self.model.toggleBasicBreakpoint(line: line) }
            },
        ] {
            g_action_map_add_action(OpaquePointer(actions), action.gAction)
        }
        gtk_widget_insert_action_group(canvas.area.widget, "listing", OpaquePointer(actions))
        g_object_unref(gpointer(actions))
        contextMenu = Popover(menu: menu)
        editor = Popover(editorHolder)

        views.add(canvas.widget, name: "listing")
        views.add(noROM.style("debugger-view"), name: "no-rom")
        views.add(noProgram.style("debugger-view"), name: "no-program")
        let root = Box(.vertical) {
            header
            Separator()
            errorWrapper
            views.expand()
            message
        }
        self.root = root
        root.track { [unowned self] in self.update() }
        root.track { [unowned self] in
            let text = self.model.message
            self.message.text = text ?? ""
            self.message.isVisible = text != nil
        }
        root.track { [unowned self] in
            let request = self.model.basicScrollRequest
            guard request != self.scrollRequest else { return }
            self.scrollRequest = request
            if let line = request?.line { self.scroll(to: line) }
        }
        root.keep(self)
    }

    private var errorWrapper: Widget!

    // MARK: State

    private func update() {
        let basic = model.basic
        if let name = basic?.interpreters.first {
            interpreter.text = name + (basic?.cpu == .parasite ? " (second processor)" : "")
        } else {
            interpreter.text = ""
        }
        current.isEnabled = basic?.stop != nil
        if let error = basic?.error {
            errorText.text = "Error \(error.number) at \(error.location): \(error.message)"
                + (error.trapped ? " (ON ERROR will handle it)" : "")
            errorWrapper.isVisible = true
        } else {
            errorWrapper.isVisible = false
        }
        if let basic, basic.interpreters.isEmpty {
            views.visible = "no-rom"
        } else if let basic, basic.lines.isEmpty {
            views.visible = "no-program"
        } else {
            views.visible = "listing"
        }
        let lines = basic?.lines ?? []
        let stop = basic?.stop
        let isError = basic?.error != nil
        let stopped = model.isStopped
        if lines != self.lines || stop != self.stop || isError != self.isError || stopped != self.stopped {
            self.lines = lines
            self.stop = stop
            self.isError = isError
            self.stopped = stopped
            numberWidth = String(lines.last?.number ?? 0).count
            canvas.setRows(lines.count)
        }
        if stop != scrolledStop {
            scrolledStop = stop
            if let line = stop?.line { scroll(to: line) }
        }
    }

    /// Shows the line (or the nearest after it) in the middle.
    private func scroll(to target: Int) {
        guard let row = lines.firstIndex(where: { $0.number >= target }) ?? (lines.isEmpty ? nil : lines.count - 1) else {
            return
        }
        canvas.scroll(to: row, anchor: 0.5)
    }

    // MARK: Drawing

    private var gutterStart: Double { 8 }
    private var arrowX: Double { gutterStart + 10 + 8 }
    private var numberX: Double { arrowX + 7 + 8 }
    private var gutterEnd: Double { numberX + Double(numberWidth) * metrics.charWidth + 4 }
    private var textX: Double { gutterEnd + 8 }

    private func draw(_ row: Int, _ painter: TextPainter, _ palette: Palette, _ y: Double, _ width: Double) {
        let cairo = painter.cairo
        let line = lines[row]
        let height = canvas.rowHeight
        let isCurrent = stop?.line == line.number
        if isCurrent {
            cairo.color(isError ? palette.breakpoint : palette.accentBackground, alpha: stopped ? 0.18 : 0.08)
            cairo.rectangle(0, y, width, height)
            cairo.fill()
        }
        let centre = y + height / 2
        let hasBreakpoint = !line.breakpoints.isEmpty
        let enabled = line.breakpoints.contains { $0.enabled }
        let conditional = line.breakpoints.contains {
            $0.condition != nil || $0.hitTarget != nil || $0.logMessage != nil || $0.statement != nil
        }
        cairo.circle(gutterStart + 5, centre, radius: hasBreakpoint ? 5 : 4.5)
        if hasBreakpoint {
            cairo.color(palette.breakpoint, alpha: enabled ? 1 : 0.3)
            cairo.fill()
            if conditional {
                cairo.color(1, 1, 1)
                cairo.circle(gutterStart + 5, centre, radius: 2)
                cairo.fill()
            }
        } else {
            cairo.color(palette.faint)
            cairo.stroke(width: 1)
        }
        if isCurrent {
            cairo.color(isError ? palette.errorText : stopped ? palette.accentText : palette.secondary)
            cairo.move(arrowX, centre - 4)
            cairo.line(arrowX + 7, centre)
            cairo.line(arrowX, centre + 4)
            cairo.fill()
        }
        let textY = y + (height - metrics.lineHeight) / 2
        let number = String(line.number)
        painter.text(String(repeating: " ", count: max(0, numberWidth - number.count)) + number, x: numberX, y: textY,
                     font: CodeFont.code, color: palette.secondary)
        // The current statement picked out when the line has more than one.
        if isCurrent, let stop, var range = Self.statement(stop.statement, in: line.text),
           range != line.text.startIndex..<line.text.endIndex {
            // (Not the space before it.)
            while range.lowerBound < range.upperBound && line.text[range.lowerBound] == " " {
                range = line.text.index(after: range.lowerBound)..<range.upperBound
            }
            let markup = Markup.escape(String(line.text[..<range.lowerBound]))
                + "<b><u>" + Markup.escape(String(line.text[range])) + "</u></b>"
                + Markup.escape(String(line.text[range.upperBound...]))
            painter.markup(markup, x: textX, y: textY, font: CodeFont.code, color: palette.foreground, width: width - textX - 8)
        } else {
            painter.text(line.text, x: textX, y: textY, font: CodeFont.code, color: palette.foreground, width: width - textX - 8)
        }
    }

    /// Where statement `n` (from 1) is in a listed line: colons outside
    /// quotes separate them.
    static func statement(_ n: Int, in text: String) -> Range<String.Index>? {
        var starts = [text.startIndex]
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c == "\"" { quoted.toggle() }
            if !quoted && c == ":" { starts.append(text.index(after: index)) }
            index = text.index(after: index)
        }
        guard n >= 1 && n <= starts.count else { return nil }
        let end = n < starts.count ? text.index(before: starts[n]) : text.endIndex
        return starts[n - 1]..<end
    }

    // MARK: Breakpoints

    /// The context menu, and the breakpoint editor, for line `number` (for
    /// the self-tests).
    func testContextMenu(line number: Int) {
        guard let row = lines.firstIndex(where: { $0.number == number }) else { return }
        showContextMenu(row, x: textX + 40, y: canvas.localTop(of: row) + canvas.rowHeight / 2)
    }

    var testPopovers: [Widget] { [contextMenu, editor] }

    func dismissPopovers() {
        contextMenu.dismiss()
        editor.dismiss()
    }

    func testEdit(line number: Int) {
        contextMenu.dismiss()
        // (Without a grab, which needs a real click.)
        gtk_popover_set_autohide(cast(editor.widget), 0)
        contextLine = number
        editContextLine()
    }

    private func showContextMenu(_ row: Int, x: Double, y: Double) {
        let line = lines[row]
        contextLine = line.number
        let hasBreakpoint = !line.breakpoints.isEmpty
        menu.set([
            MenuSection {
                MenuItem(hasBreakpoint ? "Edit Breakpoint…" : "Add Breakpoint…", "listing.edit-breakpoint")
                if hasBreakpoint {
                    MenuItem("Remove Breakpoint", "listing.remove-breakpoint")
                }
            },
        ])
        contextMenu.show(on: canvas.area, at: x, y: y)
    }

    private func editContextLine() {
        guard let number = contextLine, let row = lines.firstIndex(where: { $0.number == number }) else { return }
        edit(row)
    }

    /// The line's breakpoint: its statement, condition, hit count or log.
    /// (The Mac's BasicBreakpointEditor.)
    private func edit(_ row: Int) {
        let line = lines[row]
        let existing = line.breakpoints.first
        let number = line.number
        let statement = Entry(text: existing?.statement.map(String.init) ?? "", placeholder: "any (as the line is entered)")
        let condition = Entry(text: existing?.condition ?? "", placeholder: "BASIC, e.g. I%>10")
        let hitCount = Entry(text: existing?.hitTarget.map(String.init) ?? "", placeholder: "the first")
        let logMessage = Entry(text: existing?.logMessage ?? "", placeholder: "log instead: I%={I%}")
        for entry in [statement, condition, hitCount, logMessage] {
            entry.style("debugger-code").expand(horizontal: true)
        }
        let model = self.model
        let editor = self.editor!
        func save() {
            var b = existing ?? BasicBreakpoint(line: number)
            b.statement = Int(statement.text.trimmingCharacters(in: .whitespaces))
            b.condition = condition.text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : condition.text
            b.hitTarget = Int(hitCount.text.trimmingCharacters(in: .whitespaces))
            b.logMessage = logMessage.text.isEmpty ? nil : logMessage.text
            if existing == nil {
                model.addBasicBreakpoint(b)
            } else {
                model.updateBasicBreakpoint(b)
            }
            editor.dismiss()
        }
        for entry in [statement, condition, hitCount, logMessage] {
            entry.onActivate { save() }
        }
        let form = Grid(rowSpacing: 8, columnSpacing: 12)
            .row(0, "Statement", statement)
            .row(1, "Condition", condition)
            .row(2, "From hit", hitCount)
            .row(3, "Log", logMessage)
        let buttons = Box(.horizontal, spacing: 8)
        if let existing {
            buttons.append(Button("_Remove") {
                model.removeBasicBreakpoint(id: existing.id)
                editor.dismiss()
            }.style("destructive-action"))
        }
        buttons.append(HSpacer())
        buttons.append(Button("_Cancel") { editor.dismiss() })
        buttons.append(Button(existing == nil ? "_Add" : "_Save") { save() }.style("suggested-action"))
        editorHolder.child = Box(.vertical, spacing: 12) {
            Label("Breakpoint at line \(number)", style: "heading")
            form
            buttons
        }
        .margin(12)
        .size(width: 340)
        editor.show(on: canvas.area, at: textX, y: canvas.localTop(of: row) + canvas.rowHeight)
        statement.grabFocus()
    }
}

// MARK: Variables

@MainActor
final class BasicVariablesPane {
    let model: DebuggerModel
    private(set) var root: Widget!
    private let canvas: CodeCanvas
    private let metrics: TextMetrics
    private let views = Stack()
    private let empty = EmptyState("")
    private let filterEntry = SearchEntry(placeholder: "Filter") { _ in }
    private let showAll = CheckButton("All @%–Z%")
    private var filter = ""
    private static let showAllKey = "MacBeebBasicShowAllResident"

    private enum Row: Equatable {
        case section(String)
        /// A scalar, or an array's element (`indices`), and the name it's
        /// set by.
        case value(label: String, value: BasicValue, name: String, indices: [Int]?)
        case array(name: String, label: String, kind: String, expanded: Bool)
        case more(Int)
    }

    private var rows: [Row] = []
    private let editorHolder = Bin()
    private var editor: Popover!

    init(model: DebuggerModel) {
        self.model = model
        metrics = TextMetrics(CodeFont.small, widget: Label())
        canvas = CodeCanvas(rowHeight: metrics.lineHeight + 6)
        build()
    }

    private func build() {
        showAll.isOn = UserDefaults.standard.bool(forKey: Self.showAllKey)
        showAll.tooltip("Show the resident integers even when they're 0")
        showAll.object.on("toggled") { [unowned self] in
            UserDefaults.standard.set(self.showAll.isOn, forKey: Self.showAllKey)
            self.update()
        }
        gtk_editable_set_width_chars(cast(filterEntry.widget), 12)
        filterEntry.object.on("search-changed") { [unowned self] in
            self.filter = self.filterEntry.text
            self.update()
        }
        let header = PaneHeader("Variables") {
            HSpacer()
            showAll
            filterEntry
        }
        canvas.drawRow = { [unowned self] painter, palette, row, y, width in
            self.draw(row, painter, palette, y, width)
        }
        canvas.onPress = { [unowned self] row, x, _, presses, button, _ in
            guard row >= 0, button == 1 else { return }
            switch self.rows[row] {
            case .array(let name, _, _, _) where presses == 1:
                self.model.toggleBasicArray(name)
            case .value(let label, let value, let name, let indices) where presses == 2:
                self.edit(row, label: label, value: value, name: name, indices: indices)
            default:
                break
            }
        }
        canvas.tooltip = { [unowned self] row, _ in
            if case .value = self.rows[row] { return "Double-click to change it" }
            return nil
        }
        canvas.cursor = { [unowned self] row, _ in
            guard row >= 0, case .array = self.rows[row] else { return nil }
            return "pointer"
        }
        canvas.area.accessibleLabel("Variables")
        canvas.scroller.style("debugger-view")
        editor = Popover(editorHolder)
        views.add(canvas.widget, name: "variables")
        views.add(empty.style("debugger-view"), name: "empty")
        root = Box(.vertical) {
            header
            Separator()
            views.expand()
        }
        root.track { [unowned self] in self.update() }
        root.keep(self)
    }

    private func isResident(_ v: BasicVariable) -> Bool {
        v.address >= 0x0400 && v.address < 0x046C
    }

    private func update() {
        let basic = model.basic
        let showAllResident = showAll.isOn
        let shown = (basic?.variables ?? []).filter { v in
            v.name.hasPrefix(filter) && (showAllResident || !isResident(v) || v.value != .integer(0))
        }
        views.visible = shown.isEmpty ? "empty" : "variables"
        empty.text = filter.isEmpty ? "No variables yet: RUN the program." : "No variables starting \(filter)"
        var rows: [Row] = []
        func add(_ title: String, _ variables: [BasicVariable]) {
            guard !variables.isEmpty else { return }
            rows.append(.section(title))
            for v in variables {
                if let dimensions = v.dimensions {
                    let expanded = model.view.basicExpanded.contains(v.name)
                    rows.append(.array(name: v.name, label: v.name + dimensions.map(String.init).joined(separator: ",") + ")",
                                       kind: v.kind.rawValue, expanded: expanded))
                    guard expanded else { continue }
                    for element in basic?.elements[v.name] ?? [] {
                        rows.append(.value(label: v.name + element.indices.map(String.init).joined(separator: ",") + ")",
                                           value: element.value, name: v.name, indices: element.indices))
                    }
                    let count = dimensions.reduce(1) { $0 * ($1 + 1) }
                    if count > BasicDebugSnapshot.elementLimit {
                        rows.append(.more(count - BasicDebugSnapshot.elementLimit))
                    }
                } else if let value = v.value {
                    rows.append(.value(label: v.name, value: value, name: v.name, indices: nil))
                }
            }
        }
        add("Local", shown.filter(\.isLocal))
        add("Variables", shown.filter { !$0.isLocal && !isResident($0) && $0.dimensions == nil })
        add("Arrays", shown.filter { !$0.isLocal && $0.dimensions != nil })
        add("Resident integers", shown.filter { !$0.isLocal && isResident($0) })
        guard rows != self.rows else { return }
        self.rows = rows
        canvas.setRows(rows.count)
    }

    private func draw(_ row: Int, _ painter: TextPainter, _ palette: Palette, _ y: Double, _ width: Double) {
        let cairo = painter.cairo
        let height = canvas.rowHeight
        let textY = y + (height - metrics.lineHeight) / 2
        let x = 16.0
        switch rows[row] {
        case .section(let title):
            painter.text(title, x: x, y: y + height - metrics.lineHeight - 1, font: CodeFont.heading, color: palette.secondary)
        case .value(let label, let value, _, let indices):
            let indent = indices == nil ? x : x + 18
            let nameWidth = painter.text(label, x: indent, y: textY, font: CodeFont.small, color: palette.foreground,
                                         width: width * 0.5)
            painter.text(value.description, right: width - 12, y: textY, font: CodeFont.small, color: palette.secondary,
                         maxWidth: max(20, width - indent - nameWidth - 28))
        case .array(_, let label, let kind, let expanded):
            // A disclosure triangle.
            let cx = x + 4, cy = y + height / 2
            cairo.color(palette.secondary)
            if expanded {
                cairo.move(cx - 4, cy - 2)
                cairo.line(cx + 4, cy - 2)
                cairo.line(cx, cy + 3)
            } else {
                cairo.move(cx - 2, cy - 4)
                cairo.line(cx + 3, cy)
                cairo.line(cx - 2, cy + 4)
            }
            cairo.fill()
            painter.text(label, x: x + 14, y: textY, font: CodeFont.small, color: palette.foreground, width: width * 0.6)
            painter.text(kind, right: width - 12, y: textY, font: CodeFont.small, color: palette.secondary)
        case .more(let count):
            painter.text("…and \(count) more", x: x + 18, y: textY, font: CodeFont.small, color: palette.secondary)
        }
    }

    var testPopover: Widget { editor }

    /// Edits the first variable shown (for the self-tests).
    func testEdit() {
        gtk_popover_set_autohide(cast(editor.widget), 0)
        for (row, entry) in rows.enumerated() {
            if case .value(let label, let value, let name, let indices) = entry {
                edit(row, label: label, value: value, name: name, indices: indices)
                return
            }
        }
    }

    /// Sets a variable to a BASIC expression. (The Mac's BasicValueEditor.)
    private func edit(_ row: Int, label: String, value: BasicValue, name: String, indices: [Int]?) {
        let entry = Entry(text: value.description, placeholder: "BASIC expression")
        entry.style("debugger-code").size(width: 240)
        let model = self.model
        let editor = self.editor!
        entry.onActivate {
            model.setBasicVariable(name, indices: indices, to: entry.text)
            editor.dismiss()
        }
        editorHolder.child = Box(.vertical, spacing: 6) {
            Label("\(label) =", style: "debugger-code")
            entry
            Label("A BASIC expression: strings in quotes.", style: "dim-label", "caption")
        }
        .margin(12)
        editor.show(on: canvas.area, at: canvas.area.width > 0 ? Double(canvas.area.width) - 80 : 200,
                    y: canvas.localTop(of: row) + canvas.rowHeight)
        entry.grabFocus()
        entry.selectAll()
    }
}
