import BeebCore
import BeebHost
import SwiftUI

// The debugger window's BASIC mode: the program, its variables, the
// PROC/FN calls, BASIC breakpoints and watches.

// MARK: Listing

struct BasicListingView: View {
    @Bindable var model: DebuggerModel
    @State private var goTo = ""
    @State private var editing: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("BASIC").font(.headline)
                if let name = model.basic?.interpreters.first {
                    Text(name + (model.basic?.cpu == .parasite ? " (second processor)" : ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Go to line", text: $goTo)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit {
                        if let line = Int(goTo.trimmingCharacters(in: .whitespaces)) { model.showBasicLine(line) }
                    }
                Button("Current") {
                    if let line = model.basic?.stop?.line { model.showBasicLine(line) }
                }
                .help("Show the line it's stopped at")
                .disabled(model.basic?.stop == nil)
            }
            .padding(8)
            Divider()
            if let error = model.basic?.error {
                Label("Error \(error.number) at \(error.location): \(error.message)" + (error.trapped ? " (ON ERROR will handle it)" : ""),
                      systemImage: "exclamationmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red.opacity(0.08))
                Divider()
            }
            content
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.red).padding(6)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let basic = model.basic, basic.interpreters.isEmpty {
            placeholder("No BASIC ROM found", "Select BASIC (*BASIC) to debug a BASIC program.")
        } else if let basic = model.basic, basic.lines.isEmpty {
            placeholder("No program in memory", "Type a program in, or LOAD one. Breakpoints set in the Breakpoints tab wait for their lines.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.basic?.lines ?? []) { line in
                            BasicLineRow(line: line, stop: model.basic?.stop, isError: model.basic?.error != nil,
                                         stopped: model.isStopped, width: numberWidth) {
                                model.toggleBasicBreakpoint(line: line.number)
                            } edit: {
                                editing = line.number
                            }
                            .id(line.number)
                            .popover(isPresented: Binding(get: { editing == line.number }, set: { if !$0 { editing = nil } })) {
                                BasicBreakpointEditor(model: model, line: line.number, existing: line.breakpoints.first) {
                                    editing = nil
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.basicScrollRequest) { scroll(proxy) }
                .onChange(of: model.basic?.stop) { scroll(proxy, to: model.basic?.stop?.line) }
                .onAppear { scroll(proxy, to: model.basic?.stop?.line) }
            }
        }
    }

    private var numberWidth: Int {
        String(model.basic?.lines.last?.number ?? 0).count
    }

    private func scroll(_ proxy: ScrollViewProxy, to line: Int? = nil) {
        guard let target = line ?? model.basicScrollRequest?.line, let lines = model.basic?.lines else { return }
        // The line, or the nearest after it.
        guard let found = lines.first(where: { $0.number >= target }) ?? lines.last else { return }
        withAnimation { proxy.scrollTo(found.number, anchor: .center) }
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BasicLineRow: View {
    let line: BasicDebugSnapshot.Line
    let stop: BasicLocation?
    let isError: Bool
    let stopped: Bool
    let width: Int
    let toggle: () -> Void
    let edit: () -> Void

    private var isCurrent: Bool { stop?.line == line.number }
    private var enabled: Bool { line.breakpoints.contains { $0.enabled } }
    private var hasBreakpoint: Bool { !line.breakpoints.isEmpty }
    private var isConditional: Bool {
        line.breakpoints.contains { $0.condition != nil || $0.hitTarget != nil || $0.logMessage != nil || $0.statement != nil }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(hasBreakpoint ? (enabled ? Color.red : Color.red.opacity(0.3)) : Color.clear)
                            .overlay(Circle().stroke(Color.secondary.opacity(hasBreakpoint ? 0 : 0.25), lineWidth: 1))
                        if isConditional {
                            Circle().fill(Color.white).frame(width: 4, height: 4)
                        }
                    }
                    .frame(width: 10, height: 10)
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.caption2)
                        .foregroundStyle(isCurrent ? (isError ? Color.red : stopped ? Color.accentColor : Color.secondary) : .clear)
                    Text(String(repeating: " ", count: max(0, width - String(line.number).count)) + String(line.number))
                        .foregroundStyle(.secondary)
                }
                // The whole gutter, not just the circle's outline (a clear
                // fill isn't clickable), and no gap between rows.
                .padding(.leading, 8)
                .padding(.vertical, 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hasBreakpoint ? "Remove the breakpoint (Control-click to edit it)" : "Stop at this line (Control-click for a condition)")
            text
            Spacer(minLength: 0)
        }
        .font(codeFont)
        .padding(.trailing, 8)
        .background(isCurrent ? (isError ? Color.red : Color.accentColor).opacity(stopped ? 0.18 : 0.08) : .clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button(hasBreakpoint ? "Edit Breakpoint…" : "Add Breakpoint…", action: edit)
            if hasBreakpoint {
                Button("Remove Breakpoint", action: toggle)
            }
        }
    }

    /// The line's text, with the current statement picked out when the
    /// line has more than one.
    private var text: Text {
        guard isCurrent, let stop, let range = Self.statement(stop.statement, in: line.text),
              range != line.text.startIndex..<line.text.endIndex else {
            return Text(line.text)
        }
        let before = Text(line.text[..<range.lowerBound])
        let current = Text(line.text[range]).fontWeight(.bold).underline()
        let after = Text(line.text[range.upperBound...])
        return Text("\(before)\(current)\(after)")
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
}

/// A line's breakpoint: its statement, condition, hit count or log.
struct BasicBreakpointEditor: View {
    @Bindable var model: DebuggerModel
    let line: Int
    let existing: BasicBreakpoint?
    let done: () -> Void
    @State private var statement = ""
    @State private var condition = ""
    @State private var hitCount = ""
    @State private var logMessage = ""

    var body: some View {
        Form {
            Text("Breakpoint at line \(line)").font(.headline)
            TextField("Statement", text: $statement, prompt: Text("any (as the line is entered)"))
            TextField("Condition", text: $condition, prompt: Text("BASIC, e.g. I%>10"))
            TextField("From hit", text: $hitCount, prompt: Text("the first"))
            TextField("Log", text: $logMessage, prompt: Text("log instead: I%={I%}"))
            HStack {
                if existing != nil {
                    Button("Remove", role: .destructive) {
                        model.removeBasicBreakpoint(id: existing!.id)
                        done()
                    }
                }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            statement = existing?.statement.map(String.init) ?? ""
            condition = existing?.condition ?? ""
            hitCount = existing?.hitTarget.map(String.init) ?? ""
            logMessage = existing?.logMessage ?? ""
        }
    }

    private func save() {
        var b = existing ?? BasicBreakpoint(line: line)
        b.statement = Int(statement.trimmingCharacters(in: .whitespaces))
        b.condition = condition.trimmingCharacters(in: .whitespaces).isEmpty ? nil : condition
        b.hitTarget = Int(hitCount.trimmingCharacters(in: .whitespaces))
        b.logMessage = logMessage.isEmpty ? nil : logMessage
        if existing == nil {
            model.addBasicBreakpoint(b)
        } else {
            model.updateBasicBreakpoint(b)
        }
        done()
    }
}

// MARK: Variables

struct BasicVariablesView: View {
    @Bindable var model: DebuggerModel
    @State private var filter = ""
    @AppStorage("MacBeebBasicShowAllResident") private var showAllResident = false
    @State private var editing: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Variables").font(.headline)
                Spacer()
                Toggle("All @%–Z%", isOn: $showAllResident)
                    .toggleStyle(.checkbox)
                    .help("Show the resident integers even when they're 0")
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            .padding(8)
            Divider()
            List {
                let variables = shown
                let locals = variables.filter(\.isLocal)
                if !locals.isEmpty {
                    Section("Local") { rows(locals) }
                }
                let resident = variables.filter { !$0.isLocal && isResident($0) }
                let others = variables.filter { !$0.isLocal && !isResident($0) && $0.dimensions == nil }
                let arrays = variables.filter { !$0.isLocal && $0.dimensions != nil }
                if !others.isEmpty { Section("Variables") { rows(others) } }
                if !arrays.isEmpty { Section("Arrays") { rows(arrays) } }
                if !resident.isEmpty { Section("Resident integers") { rows(resident) } }
            }
            .font(smallCodeFont)
            .overlay {
                if shown.isEmpty {
                    Text(filter.isEmpty ? "No variables yet: RUN the program." : "No variables starting \(filter)")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var shown: [BasicVariable] {
        (model.basic?.variables ?? []).filter { v in
            v.name.hasPrefix(filter) && (showAllResident || !isResident(v) || v.value != .integer(0))
        }
    }

    private func isResident(_ v: BasicVariable) -> Bool {
        v.address >= 0x0400 && v.address < 0x046C
    }

    @ViewBuilder private func rows(_ variables: [BasicVariable]) -> some View {
        ForEach(variables, id: \.name) { v in
            if let dimensions = v.dimensions {
                DisclosureGroup(isExpanded: Binding(get: { model.view.basicExpanded.contains(v.name) },
                                                    set: { _ in model.toggleBasicArray(v.name) })) {
                    ForEach(model.basic?.elements[v.name] ?? []) { element in
                        let name = v.name + element.indices.map(String.init).joined(separator: ",") + ")"
                        valueRow(name, element.value, set: { model.setBasicVariable(v.name, indices: element.indices, to: $0) })
                    }
                    let count = dimensions.reduce(1) { $0 * ($1 + 1) }
                    if count > BasicDebugSnapshot.elementLimit {
                        Text("…and \(count - BasicDebugSnapshot.elementLimit) more").foregroundStyle(.secondary)
                    }
                } label: {
                    HStack {
                        Text(v.name + dimensions.map(String.init).joined(separator: ",") + ")")
                        Spacer()
                        Text(v.kind.rawValue).foregroundStyle(.secondary)
                    }
                }
            } else if let value = v.value {
                valueRow(v.name, value, set: { model.setBasicVariable(v.name, to: $0) })
            }
        }
    }

    private func valueRow(_ name: String, _ value: BasicValue, set: @escaping (String) -> Void) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value.description)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = name }
        .help("Double-click to change it")
        .popover(isPresented: Binding(get: { editing == name }, set: { if !$0 { editing = nil } })) {
            BasicValueEditor(name: name, value: value) { text in
                set(text)
                editing = nil
            }
        }
    }
}

struct BasicValueEditor: View {
    let name: String
    let value: BasicValue
    let set: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(name) =").font(codeFont)
            TextField("BASIC expression", text: $text)
                .font(codeFont)
                .frame(width: 240)
                .onSubmit { set(text) }
            Text("A BASIC expression: strings in quotes.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { text = value.description }
    }
}

// MARK: Sidebar

struct BasicSidebar: View {
    @Bindable var model: DebuggerModel
    @AppStorage("MacBeebBasicDebuggerTab") private var tab = Tab.calls

    enum Tab: String, CaseIterable {
        case calls = "Calls", breakpoints = "Breakpoints", watch = "Watch", log = "Log"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch tab {
            case .calls: BasicCallsView(model: model)
            case .breakpoints: BasicBreakpointsView(model: model)
            case .watch: BasicWatchView(model: model)
            case .log: LogView(model: model)
            }
        }
    }
}

struct BasicCallsView: View {
    @Bindable var model: DebuggerModel

    var body: some View {
        List(Array((model.basic?.frames ?? []).enumerated()), id: \.offset) { index, frame in
            Button {
                if let line = frame.location?.line { model.showBasicLine(line) }
            } label: {
                VStack(alignment: .leading) {
                    Text(frame.name.map { $0 == "?" ? "(not followed further)" : $0 } ?? "Main program")
                        .font(smallCodeFont)
                        .fontWeight(index == 0 ? .bold : .regular)
                    Text(frame.location.map { (index == 0 ? "at " : "called at ") + "\($0)" } ?? "from a command typed in")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if model.basic?.frames.isEmpty ?? true {
                Text("Stop in the program (a breakpoint, a step, or Pause in BASIC) to see its PROC and FN calls.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
    }
}

struct BasicBreakpointsView: View {
    @Bindable var model: DebuggerModel
    @State private var line = ""
    @State private var statement = ""
    @State private var condition = ""
    @State private var logMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Stop on errors", selection: Binding(get: { model.basic?.errorStop ?? .off },
                                                         set: { model.setBasicErrorStop($0) })) {
                Text("Off").tag(BasicDebugger.ErrorStop.off)
                Text("Untrapped").tag(BasicDebugger.ErrorStop.untrapped)
                Text("All").tag(BasicDebugger.ErrorStop.all)
            }
            .pickerStyle(.segmented)
            .help("Stop where an error happens: those no ON ERROR handles (Escape and STOP too), or all of them")
            .padding(8)
            Divider()
            List {
                ForEach(model.basic?.breakpoints ?? []) { b in
                    HStack {
                        Toggle("", isOn: Binding(get: { b.enabled }, set: { on in
                            var changed = b
                            changed.enabled = on
                            model.updateBasicBreakpoint(changed)
                        }))
                        .labelsHidden()
                        Button {
                            model.showBasicLine(b.line)
                        } label: {
                            VStack(alignment: .leading) {
                                Text("Line \(b.line)" + (b.statement.map { " statement \($0)" } ?? "")).font(smallCodeFont)
                                if let detail = detail(b) {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Text("\(b.hitCount)").font(.caption).foregroundStyle(.secondary).help("Hits")
                        Button { model.removeBasicBreakpoint(id: b.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Divider()
            Form {
                TextField("Line", text: $line, prompt: Text("e.g. 120"))
                TextField("Statement", text: $statement, prompt: Text("optional: 1 is the first"))
                TextField("Condition", text: $condition, prompt: Text("BASIC, e.g. I%>10"))
                TextField("Log", text: $logMessage, prompt: Text("log instead of stopping: I%={I%}"))
                HStack {
                    Button("Add Breakpoint", action: add)
                        .disabled(Int(line.trimmingCharacters(in: .whitespaces)) == nil)
                    Spacer()
                    Button("Remove All") { model.removeAllBasicBreakpoints() }
                        .disabled(model.basic?.breakpoints.isEmpty ?? true)
                }
            }
            .padding(8)
        }
    }

    private func add() {
        guard let number = Int(line.trimmingCharacters(in: .whitespaces)) else { return }
        model.addBasicBreakpoint(BasicBreakpoint(line: number, statement: Int(statement.trimmingCharacters(in: .whitespaces)),
                                                 condition: condition.trimmingCharacters(in: .whitespaces).isEmpty ? nil : condition,
                                                 logMessage: logMessage.isEmpty ? nil : logMessage))
        line = ""
        statement = ""
        condition = ""
        logMessage = ""
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

struct BasicWatchView: View {
    @Bindable var model: DebuggerModel
    @State private var expression = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Expression", text: $expression, prompt: Text("e.g. total/count%"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Watch", action: add)
            }
            .padding(8)
            Divider()
            List(model.basic?.watches ?? []) { watch in
                HStack(alignment: .firstTextBaseline) {
                    Text(watch.expression).font(smallCodeFont)
                    Spacer()
                    switch watch.result {
                    case .success(let value):
                        Text(value.description).font(smallCodeFont).foregroundStyle(.secondary).lineLimit(1)
                    case .failure(let error):
                        Text(error.message).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                    Button { model.removeBasicWatch(watch.expression) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            .overlay {
                if model.basic?.watches.isEmpty ?? true {
                    Text("Watch BASIC expressions: variables, array elements, arithmetic and comparisons. They update as the program runs.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
        }
    }

    private func add() {
        model.addBasicWatch(expression)
        expression = ""
    }
}
