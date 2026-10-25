import BeebCore
import BeebHost
import SwiftUI

/// Parses &FF, $FF, 0xFF, %101 or decimal.
func parseNumber(_ text: String) -> Int? {
    let s = text.trimmingCharacters(in: .whitespaces)
    for prefix in ["&", "$", "0x", "0X"] where s.hasPrefix(prefix) {
        return Int(s.dropFirst(prefix.count), radix: 16)
    }
    if s.hasPrefix("%") { return Int(s.dropFirst(), radix: 2) }
    return Int(s)
}

func hex(_ value: some BinaryInteger, _ digits: Int = 2) -> String {
    let text = String(value, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, digits - text.count)) + text
}

let codeFont = Font.system(.body, design: .monospaced)
let smallCodeFont = Font.system(.callout, design: .monospaced)

struct DebuggerWindow: View {
    @Bindable var model: DebuggerModel
    var machineName: String

    var body: some View {
        HSplitView {
            if model.view.basic {
                VSplitView {
                    BasicListingView(model: model)
                        .frame(minHeight: 220, idealHeight: 440)
                    BasicVariablesView(model: model)
                        .frame(minHeight: 160, idealHeight: 280)
                }
                .frame(minWidth: 520, idealWidth: 640)
                BasicSidebar(model: model)
                    .frame(minWidth: 300, idealWidth: 360)
            } else {
                VSplitView {
                    DisassemblyView(model: model)
                        .frame(minHeight: 220, idealHeight: 420)
                    MemoryView(model: model)
                        .frame(minHeight: 180, idealHeight: 300)
                }
                .frame(minWidth: 520, idealWidth: 640)
                DebuggerSidebar(model: model)
                    .frame(minWidth: 300, idealWidth: 360)
            }
        }
        .toolbar { DebuggerToolbar(model: model) }
        .navigationTitle("Debugger — \(machineName)")
        .onAppear { model.isVisible = true }
        .onDisappear { model.isVisible = false }
    }
}

struct DebuggerToolbar: ToolbarContent {
    @Bindable var model: DebuggerModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $model.view.basic) {
                Text("Machine Code").tag(false)
                Text("BASIC").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Debug machine code, or a BASIC program by its lines")
        }
        ToolbarItem(placement: .navigation) {
            if model.snapshot?.hasSecondProcessor == true && !model.view.basic {
                Picker("CPU", selection: $model.view.cpu) {
                    Text("Host").tag(DebugCPU.host)
                    Text("Second Processor").tag(DebugCPU.parasite)
                }
                .pickerStyle(.segmented)
                .help("Which CPU to show and step")
            }
        }
        if model.view.basic {
            basicItems
        } else {
            machineCodeItems
        }
        ToolbarItem(placement: .status) {
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var f6: KeyEquivalent { KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!)) }
    private var f7: KeyEquivalent { KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!)) }
    private var f8: KeyEquivalent { KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)) }

    @ToolbarContentBuilder private var basicItems: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.basicPauseOrContinue() } label: {
                Label(model.isStopped ? "Continue" : "Pause",
                      systemImage: model.isStopped ? "play.fill" : "pause.fill")
            }
            .keyboardShortcut("y", modifiers: [.command, .control])
            .help(model.isStopped ? "Continue (⌃⌘Y)" : "Pause (⌃⌘Y): at the next BASIC statement")

            Button { model.basicStep(.over) } label: { Label("Step Over", systemImage: "arrow.turn.down.right") }
                .keyboardShortcut(f6, modifiers: [])
                .help("Step over (F6): to the next statement, running PROCs, FNs and GOSUBs through")
                .disabled(!model.isStopped)
            Button { model.basicStep(.into) } label: { Label("Step Into", systemImage: "arrow.down.to.line") }
                .keyboardShortcut(f7, modifiers: [])
                .help("Step into (F7): to the next statement, into PROCs, FNs and GOSUBs")
                .disabled(!model.isStopped)
            Button { model.basicStep(.out) } label: { Label("Step Out", systemImage: "arrow.up.to.line") }
                .keyboardShortcut(f8, modifiers: [])
                .help("Step out (F8): until this PROC, FN or subroutine returns")
                .disabled(!model.isStopped)
        }
    }

    @ToolbarContentBuilder private var machineCodeItems: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.pauseOrContinue() } label: {
                Label(model.isStopped ? "Continue" : "Pause",
                      systemImage: model.isStopped ? "play.fill" : "pause.fill")
            }
            .keyboardShortcut("y", modifiers: [.command, .control])
            .help(model.isStopped ? "Continue (⌃⌘Y)" : "Pause (⌃⌘Y)")

            Button { model.run(.stepOver) } label: { Label("Step Over", systemImage: "arrow.turn.down.right") }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!)), modifiers: [])
                .help("Step over (F6): a JSR runs to the next instruction")
                .disabled(!model.isStopped)
            Button { model.run(.stepInstruction) } label: { Label("Step Into", systemImage: "arrow.down.to.line") }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!)), modifiers: [])
                .help("Step into (F7): one instruction")
                .disabled(!model.isStopped)
            Button { model.run(.stepOut) } label: { Label("Step Out", systemImage: "arrow.up.to.line") }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)), modifiers: [])
                .help("Step out (F8): until this subroutine or interrupt returns")
                .disabled(!model.isStopped)
            Button { model.stepBack() } label: { Label("Step Back", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!)), modifiers: [.shift])
                .help("Step back (⇧F7): to the previous instruction, from the rewind history")
                .disabled(!model.isStopped)
            Button { model.reverseContinue() } label: { Label("Reverse Continue", systemImage: "backward.end.fill") }
                .keyboardShortcut("y", modifiers: [.command, .control, .shift])
                .help("Reverse continue (⇧⌃⌘Y): back to the last breakpoint hit")
                .disabled(!model.isStopped)
            Menu {
                Button("One Cycle") { model.run(.stepCycle) }
                Button("Next Scanline") { model.run(.nextScanline) }
                Button("Next Frame") { model.run(.nextFrame) }
                Button("Next Interrupt") { model.run(.nextInterrupt) }
            } label: {
                Label("Step By", systemImage: "forward.frame")
            }
            .help("Step by a cycle, scanline, frame or to the next interrupt")
        }
    }

    private var statusText: String {
        guard let snapshot = model.snapshot else { return "" }
        if let reason = snapshot.stopReason {
            return "Stopped: \(reason)"
        }
        if snapshot.isRunningCommand && snapshot.view.basic {
            return "Running to a BASIC statement…"
        }
        return snapshot.isRunningCommand ? "Stepping…" : "Running"
    }
}

// MARK: Disassembly

struct DisassemblyView: View {
    @Bindable var model: DebuggerModel
    @State private var goTo = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Disassembly").font(.headline)
                Spacer()
                TextField("Go to address", text: $goTo)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit(go)
                Button("PC") { model.view.disassemblyStart = nil }
                    .help("Follow the program counter")
                Button { loadSymbols() } label: { Image(systemName: "tag") }
                    .help("Load symbols: ld65 debug info (.dbg) or a label file")
                Button { shift(-1) } label: { Image(systemName: "chevron.up") }
                    .help("Earlier")
                Button { shift(1) } label: { Image(systemName: "chevron.down") }
                    .help("Later")
            }
            .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.snapshot?.disassembly ?? []) { line in
                        DisassemblyRow(line: line, stopped: model.isStopped) {
                            model.toggleBreakpoint(at: line.address)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.red).padding(6)
            }
        }
    }

    private func loadSymbols() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.message = "Choose ld65 debug info (ld65 --dbgfile) or a label file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.loadSymbols(url)
    }

    private func go() {
        let text = goTo
        Task {
            if let address = await model.address(text) {
                model.view.disassemblyStart = UInt16(truncatingIfNeeded: address)
            }
        }
    }

    private func shift(_ direction: Int) {
        let lines = model.snapshot?.disassembly ?? []
        guard let first = lines.first else { return }
        if direction > 0 {
            model.view.disassemblyStart = lines[min(lines.count - 1, lines.count / 2)].address
        } else {
            model.view.disassemblyStart = first.address &- 48
        }
    }
}

struct DisassemblyRow: View {
    let line: DebugSnapshot.Line
    let stopped: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(line.labels, id: \.self) { label in
                Text(label + ":")
                    .font(codeFont)
                    .foregroundStyle(.tint)
                    .padding(.leading, 44)
            }
            row
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(line.breakpoints.isEmpty ? Color.clear : Color.red)
                        .overlay(Circle().stroke(Color.secondary.opacity(line.breakpoints.isEmpty ? 0.25 : 0), lineWidth: 1))
                        .frame(width: 10, height: 10)
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.caption2)
                        .foregroundStyle(line.isPC ? (stopped ? Color.accentColor : Color.secondary) : .clear)
                    Text(hex(line.address, 4)).foregroundStyle(.secondary)
                }
                // The whole gutter, not just the circle's outline (a clear
                // fill isn't clickable), and no gap between rows.
                .padding(.leading, 8)
                .padding(.vertical, 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(line.breakpoints.isEmpty ? "Set a breakpoint" : "Remove the breakpoint")
            Text(line.bytes.map { hex($0) }.joined(separator: " "))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(line.text)
            Spacer()
            if let source = line.source {
                Text(source.description).foregroundStyle(.secondary).font(smallCodeFont)
            }
        }
        .font(codeFont)
        .padding(.trailing, 8)
        .background(alignment: .leading) {
            // Profile heat: a bar in proportion to the busiest instruction.
            if let heat = line.heat {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.orange.opacity(0.12 + 0.3 * heat))
                        .frame(width: max(3, geometry.size.width * 0.25 * heat))
                }
            }
        }
        .background(line.isPC ? Color.accentColor.opacity(stopped ? 0.18 : 0.08) : .clear)
        .contentShape(Rectangle())
    }
}

// MARK: Memory

struct MemoryView: View {
    @Bindable var model: DebuggerModel
    @State private var addressText = ""
    @State private var editing: Int?
    @State private var editText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Memory").font(.headline)
                Picker("Space", selection: $model.view.memorySpace) {
                    ForEach(model.snapshot?.regions ?? [], id: \.space) { region in
                        Text(region.name).tag(region.space)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                Spacer()
                TextField("Address", text: $addressText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit(go)
                Button { page(-1) } label: { Image(systemName: "chevron.up") }
                Button { page(1) } label: { Image(systemName: "chevron.down") }
            }
            .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let memory = model.snapshot?.memory ?? []
                    let base = model.snapshot?.view.memoryAddress ?? 0
                    ForEach(0..<(memory.count / 16), id: \.self) { row in
                        memoryRow(row, memory: memory, base: base)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func memoryRow(_ row: Int, memory: [UInt8?], base: Int) -> some View {
        HStack(spacing: 4) {
            Text(hex(base + row * 16, 4)).foregroundStyle(.secondary)
                .padding(.trailing, 6)
            ForEach(0..<16, id: \.self) { column in
                let index = row * 16 + column
                let value = memory[index]
                let changed = model.previousMemory.count == memory.count && model.previousMemory[index] != value
                Text(value.map { hex($0) } ?? "--")
                    .foregroundStyle(changed ? Color.orange : value == nil ? .secondary : .primary)
                    .fontWeight(changed ? .bold : .regular)
                    .onTapGesture(count: 2) {
                        editing = base + index
                        editText = value.map { hex($0) } ?? ""
                    }
                    .popover(isPresented: Binding(get: { editing == base + index }, set: { if !$0 { editing = nil } })) {
                        TextField("Value", text: $editText)
                            .frame(width: 80)
                            .padding()
                            .onSubmit {
                                if let v = parseNumber(editText.hasPrefix("&") || editText.hasPrefix("$") ? editText : "&" + editText),
                                   (0...255).contains(v) {
                                    model.write(UInt8(v), at: base + index)
                                }
                                editing = nil
                            }
                    }
                if column == 7 { Text(" ") }
            }
            Text(String(memory[row * 16..<row * 16 + 16].map { b -> Character in
                guard let b, b >= 32 && b < 127 else { return "." }
                return Character(UnicodeScalar(b))
            }))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
        }
        .font(smallCodeFont)
        .padding(.horizontal, 8)
    }

    private func go() {
        let text = addressText
        Task {
            if let address = await model.address(text) {
                model.view.memoryAddress = max(0, address & ~0xF)
            }
        }
    }

    private func page(_ direction: Int) {
        model.view.memoryAddress = max(0, model.view.memoryAddress + direction * 256)
    }
}

// MARK: Sidebar

struct DebuggerSidebar: View {
    @Bindable var model: DebuggerModel
    @AppStorage("MacBeebDebuggerTab") private var tab = Tab.cpu

    enum Tab: String, CaseIterable {
        case cpu = "CPU", breakpoints = "Breakpoints", hardware = "Hardware", trace = "Trace", profile = "Profile", log = "Log"
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
            case .cpu: RegistersView(model: model)
            case .breakpoints: BreakpointsView(model: model)
            case .hardware: HardwareView(model: model)
            case .trace: TraceView(model: model)
            case .profile: ProfileView(model: model)
            case .log: LogView(model: model)
            }
        }
    }
}

struct RegistersView: View {
    @Bindable var model: DebuggerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let state = model.snapshot?.state(model.cpu) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        ForEach(state.registers) { register in
                            registerRow(register.name, register.value, digits: register.digits)
                        }
                    }
                    // A Z80's flags and flip-flops wrap onto a second row.
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(state.kind == .z80 ? 44 : 30), spacing: 6), count: 8),
                              alignment: .leading, spacing: 6) {
                        ForEach(state.flags) { flag in
                            Button(flag.label) {
                                if let name = flag.register { model.setRegister(name, to: flag.set ? 0 : 1) }
                            }
                            .buttonStyle(.bordered)
                            .tint(flag.set ? .accentColor : .secondary)
                            .disabled(!model.isStopped || flag.register == nil)
                        }
                    }
                    .font(codeFont)
                    if !state.atInstruction {
                        Label("Mid-instruction: step to finish it", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Cycle \(model.snapshot?.cycles ?? 0)").font(.callout).foregroundStyle(.secondary)
                    Divider()
                    Text("Stack").font(.headline)
                    ForEach(model.snapshot?.stack ?? [], id: \.address) { entry in
                        HStack {
                            Text(hex(entry.address, 4)).foregroundStyle(.secondary)
                            Text(hex(entry.value))
                        }
                        .font(smallCodeFont)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func registerRow(_ name: String, _ value: Int, digits: Int = 2) -> some View {
        GridRow {
            Text(name).font(codeFont).foregroundStyle(.secondary)
            RegisterField(value: value, digits: digits, enabled: model.isStopped) { model.setRegister(name, to: $0) }
            Text("\(value)").font(smallCodeFont).foregroundStyle(.secondary)
        }
    }
}

struct RegisterField: View {
    let value: Int
    let digits: Int
    let enabled: Bool
    let set: (Int) -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .font(codeFont)
            .textFieldStyle(.roundedBorder)
            .frame(width: digits == 4 ? 70 : 46)
            .disabled(!enabled)
            .onAppear { text = "&" + hex(value, digits) }
            .onChange(of: value) { text = "&" + hex(value, digits) }
            .onSubmit {
                if let v = parseNumber(text.hasPrefix("&") || text.hasPrefix("$") ? text : "&" + text) {
                    set(v)
                } else {
                    text = "&" + hex(value, digits)
                }
            }
    }
}

struct BreakpointsView: View {
    @Bindable var model: DebuggerModel
    @State private var address = ""
    @State private var end = ""
    @State private var kind = "execute"
    @State private var condition = ""
    @State private var logMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(model.snapshot?.breakpoints ?? []) { b in
                    HStack {
                        Toggle("", isOn: Binding(get: { b.enabled }, set: { on in
                            var changed = b
                            changed.enabled = on
                            model.updateBreakpoint(changed)
                        }))
                        .labelsHidden()
                        VStack(alignment: .leading) {
                            Text(title(b)).font(smallCodeFont)
                            if let detail = detail(b) {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(b.hitCount)").font(.caption).foregroundStyle(.secondary).help("Hits")
                        Button { model.removeBreakpoint(id: b.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Divider()
            Form {
                TextField("Address", text: $address, prompt: Text("&1900 or expression"))
                TextField("To", text: $end, prompt: Text("optional end of range"))
                Picker("Stop on", selection: $kind) {
                    Text("Execute").tag("execute")
                    Text("Read").tag("read")
                    Text("Write").tag("write")
                    Text("Read or write").tag("access")
                }
                TextField("Condition", text: $condition, prompt: Text("e.g. A == &41"))
                TextField("Log", text: $logMessage, prompt: Text("log instead of stopping: A={A}"))
                HStack {
                    Button("Add Breakpoint", action: add)
                    Spacer()
                    Button("Remove All") { model.removeAllBreakpoints() }
                        .disabled(model.snapshot?.breakpoints.isEmpty ?? true)
                }
            }
            .padding(8)
        }
    }

    private func add() {
        let (text, endText) = (address, end)
        let kinds: [String: Breakpoint.Kind] = ["execute": .execute, "read": .read, "write": .write, "access": .access]
        let breakpointKind = kinds[kind] ?? .execute
        let cpu = model.cpu
        let condition = self.condition.isEmpty ? nil : self.condition
        let log = logMessage.isEmpty ? nil : logMessage
        Task {
            guard let start = await model.address(text) else {
                model.message = "Bad address: \(text)"
                return
            }
            let last = endText.isEmpty ? start : (await model.address(endText) ?? start)
            model.addBreakpoint(Breakpoint(cpu: cpu, kind: breakpointKind, start: UInt16(truncatingIfNeeded: start),
                                           end: UInt16(truncatingIfNeeded: last), condition: condition, logMessage: log))
            address = ""
            end = ""
        }
    }

    private func title(_ b: Breakpoint) -> String {
        let kind = b.kind == .execute ? "exec" : b.kind == .read ? "read" : b.kind == .write ? "write" : "r/w"
        let range = "&" + hex(b.start, 4) + (b.end != b.start ? "-&" + hex(b.end, 4) : "")
        return "\(kind) \(range)" + (b.cpu == .parasite ? " (2P)" : "")
    }

    private func detail(_ b: Breakpoint) -> String? {
        var parts: [String] = []
        if let c = b.condition { parts.append("if \(c)") }
        if let l = b.logMessage { parts.append("log \(l)") }
        if let h = b.hitTarget { parts.append("from hit \(h)") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

struct HardwareView: View {
    @Bindable var model: DebuggerModel

    var body: some View {
        List {
            ForEach(model.snapshot?.hardware ?? []) { section in
                Section(section.name) {
                    ForEach(section.rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(row.value).font(smallCodeFont).multilineTextAlignment(.trailing)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

struct TraceView: View {
    @Bindable var model: DebuggerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Record the last 100,000 instructions", isOn: Binding(
                get: { model.snapshot?.tracing ?? false },
                set: { model.setTracing($0) }
            ))
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                List(model.snapshot?.trace ?? []) { line in
                    HStack(spacing: 8) {
                        Text(hex(line.entry.pc, 4)).foregroundStyle(.secondary)
                        Text(line.text).frame(width: 130, alignment: .leading)
                        Text(line.entry.registerText)
                            .foregroundStyle(.secondary)
                    }
                    .font(smallCodeFont)
                    .id(line.id)
                }
                .onChange(of: model.snapshot?.trace.last?.entry.cycle) {
                    if let last = model.snapshot?.trace.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

struct LogView: View {
    @Bindable var model: DebuggerModel

    var body: some View {
        List(Array((model.snapshot?.log ?? []).enumerated()), id: \.offset) { _, entry in
            VStack(alignment: .leading) {
                Text(entry.text).font(smallCodeFont)
                Text("\(entry.cpu == .host ? "host" : "2P"), cycle \(entry.cycle)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if model.snapshot?.log.isEmpty ?? true {
                Text("Log points' output appears here. Add a breakpoint with a log message to log instead of stopping.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
    }
}

struct ProfileView: View {
    @Bindable var model: DebuggerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(model.snapshot?.isProfiling == true ? "Stop Profiling" : "Start Profiling") {
                    model.setProfiling(!(model.snapshot?.isProfiling ?? false))
                }
                Spacer()
                if let profile = model.snapshot?.profile {
                    Text(summary(profile)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            Divider()
            if let profile = model.snapshot?.profile, profile.totalCycles > 0 {
                List {
                    Section("Routines") {
                        ForEach(profile.routines.prefix(30)) { routine in
                            row(routine.name, routine.cycles, of: profile.totalCycles)
                        }
                    }
                    Section("Busiest instructions") {
                        ForEach(profile.hottest) { entry in
                            row("&" + hex(entry.address, 4) + "  ×\(entry.executions)", entry.cycles, of: profile.totalCycles)
                        }
                    }
                }
            } else {
                Text("Start profiling to count the cycles spent at every address. The disassembly shows where the time goes; routines are grouped by symbol.")
                    .font(.callout).foregroundStyle(.secondary).padding()
                Spacer()
            }
        }
    }

    private func summary(_ p: ProfileReport) -> String {
        let interrupts = p.totalCycles > 0 ? Double(p.interruptCycles) * 100 / Double(p.totalCycles) : 0
        return String(format: "%d frames, %.0f cycles/frame, %.1f%% in interrupts", p.frames, p.cyclesPerFrame, interrupts)
    }

    private func row(_ name: String, _ cycles: Int, of total: Int) -> some View {
        let share = Double(cycles) / Double(max(total, 1))
        return HStack {
            Text(String(format: "%5.1f%%", share * 100)).font(smallCodeFont).frame(width: 56, alignment: .trailing)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.orange.opacity(0.15))
                Rectangle().fill(Color.orange.opacity(0.6)).frame(width: 60 * share)
            }
            .frame(width: 60, height: 6)
            Text(name).font(smallCodeFont).lineLimit(1)
        }
    }
}
