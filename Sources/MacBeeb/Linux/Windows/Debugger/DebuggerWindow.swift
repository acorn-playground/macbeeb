import BeebCore
import BeebHost
import CGtk
import Foundation

/// A machine's debugger: machine code (disassembly, memory, the CPU, the
/// hardware) or BASIC (the program, its variables and calls), stepped and
/// run from the header bar. One per machine. (The Mac's DebuggerWindow and
/// its toolbar.)
@MainActor
enum DebuggerWindow {
    static func show(for machine: MachineController) {
        Windows.show("debugger-\(machine.id)") {
            DebuggerController(machine: machine).window
        }
    }
}

@MainActor
final class DebuggerController {
    let machine: MachineController
    let model: DebuggerModel
    let window: Window
    private let windowTitle = WindowTitle("Debugger")
    private var actions: [String: Action] = [:]
    private var closeTimer: MainTimer?

    private let viewSwitch: ToggleGroup
    private let cpuSwitch: ToggleGroup
    private let content = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    private let continueButton = Button(icon: "media-playback-start-symbolic")
    private var machineCodeOnly: [Widget] = []
    private var continueShows: (stopped: Bool, basic: Bool)?

    private(set) var disassembly: DisassemblyPane!
    private(set) var memory: MemoryPane!
    private(set) var listing: BasicListingPane!
    private(set) var variables: BasicVariablesPane!

    init(machine: MachineController) {
        self.machine = machine
        model = machine.debugger
        DebuggerStyles.install()
        window = Window(title: "Debugger — \(machine.model.displayName)", width: 1100, height: 760)
        window.minimumSize(width: 860, height: 560)
        let model = self.model
        viewSwitch = ToggleGroup(["Machine Code", "BASIC"], selected: model.view.basic ? 1 : 0) { index in
            if model.view.basic != (index == 1) { model.view.basic = index == 1 }
        }
        cpuSwitch = ToggleGroup(["Host", "Second Processor"], selected: model.view.cpu == .parasite ? 1 : 0) { index in
            let cpu: DebugCPU = index == 1 ? .parasite : .host
            if model.view.cpu != cpu { model.view.cpu = cpu }
        }
        buildActions()
        let header = buildHeaderBar()
        buildContent()
        window.content = ToolbarView(content: content).top(header)
        App.addStandardShortcuts(to: window)
        observe()
        window.onMap { [weak self] in
            model.isVisible = true
            // (Nothing focused at first: the go-to fields wait to be asked.
            // GTK picks a focus after this.)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let window = self?.window.window { gtk_window_set_focus(window, nil) }
                }
            }
        }
        window.onUnmap { if model.isVisible { model.isVisible = false } }
        window.onDestroy { [weak self] in
            if model.isVisible { model.isVisible = false }
            self?.closeTimer?.invalidate()
        }
        // The machine gone (its window closed, or a station switched off):
        // so is its debugger.
        closeTimer = MainTimer.repeating(every: 1) { [weak self] in
            guard let self else { return }
            let machine = self.machine
            let gone = MachineController.all[machine.id] == nil
                || (!machine.isStation && MachineWindow.existing(for: machine) == nil)
            if gone { self.window.close() }
        }
        window.keep(self)
        DebuggerSelfTest.start(self)
    }

    // MARK: Actions

    private func buildActions() {
        let model = self.model
        func command(_ name: String, _ body: @escaping @MainActor () -> Void) {
            actions[name] = window.action(name, body)
        }
        command("continue") {
            if model.view.basic { model.basicPauseOrContinue() } else { model.pauseOrContinue() }
        }
        // (The app's Alt+Y, Break into Debugger or Continue, here too.)
        command("break-into-debugger") {
            if model.view.basic { model.basicPauseOrContinue() } else { model.pauseOrContinue() }
        }
        command("step-over") {
            if model.view.basic { model.basicStep(.over) } else { model.run(.stepOver) }
        }
        command("step-into") {
            if model.view.basic { model.basicStep(.into) } else { model.run(.stepInstruction) }
        }
        command("step-out") {
            if model.view.basic { model.basicStep(.out) } else { model.run(.stepOut) }
        }
        command("step-back") { model.stepBack() }
        command("reverse-continue") { model.reverseContinue() }
        command("step-cycle") { model.run(.stepCycle) }
        command("next-scanline") { model.run(.nextScanline) }
        command("next-frame") { model.run(.nextFrame) }
        command("next-interrupt") { model.run(.nextInterrupt) }
        command("go-to") { [weak self] in
            guard let self else { return }
            let entry = model.view.basic ? self.listing.goTo : self.disassembly.goTo
            entry.grabFocus()
            entry.selectAll()
        }
        // (The Mac's ⌃⌘Y and ⇧⌃⌘Y are Alt+Y and Shift+Alt+Y here, as Alt+Y
        // breaks into the debugger from a machine's window.)
        for (trigger, action) in [("<Alt>y", "continue"), ("F6", "step-over"), ("F7", "step-into"), ("F8", "step-out"),
                                  ("<Shift>F7", "step-back"), ("<Alt><Shift>y", "reverse-continue"),
                                  ("<Control>l", "go-to"), ("<Control>i", "go-to")] {
            window.shortcut(trigger, action: "win." + action)
        }
    }

    // MARK: The header bar

    private func buildHeaderBar() -> HeaderBar {
        let header = HeaderBar(title: windowTitle)
        viewSwitch.tooltip("Debug machine code, or a BASIC program by its lines")
        cpuSwitch.tooltip("Which CPU to show and step")
        header.start(viewSwitch)
        header.start(cpuSwitch)

        func tool(_ icon: String, _ action: String, _ label: String, _ help: String) -> Button {
            Button(icon: icon).action("win." + action).tooltip(help).accessibleLabel(label)
        }
        continueButton.action("win.continue")
        let stepOver = tool("macbeeb-step-over-symbolic", "step-over", "Step Over", "")
        let stepInto = tool("macbeeb-step-into-symbolic", "step-into", "Step Into", "")
        let stepOut = tool("macbeeb-step-out-symbolic", "step-out", "Step Out", "")
        let stepBack = tool("edit-undo-symbolic", "step-back", "Step Back",
                            "Step back (Shift+F7): to the previous instruction, from the rewind history")
        let reverse = tool("media-skip-backward-symbolic", "reverse-continue", "Reverse Continue",
                           "Reverse continue (Shift+Alt+Y): back to the last breakpoint hit")
        let stepBy = MenuButton(icon: "media-seek-forward-symbolic", menu: Menu {
            MenuSection {
                MenuItem("One Cycle", "win.step-cycle")
                MenuItem("Next Scanline", "win.next-scanline")
                MenuItem("Next Frame", "win.next-frame")
                MenuItem("Next Interrupt", "win.next-interrupt")
            }
        })
        stepBy.tooltip("Step by a cycle, scanline, frame or to the next interrupt").accessibleLabel("Step By")
        machineCodeOnly = [stepBack, reverse, stepBy]
        let controls = Box(.horizontal, spacing: 2) {
            continueButton
            Separator(GTK_ORIENTATION_VERTICAL).margin(horizontal: 4, vertical: 8).style("spacer")
            stepOver
            stepInto
            stepOut
            stepBack
            reverse
            stepBy
        }
        header.end(controls)
        // The tooltips say what each does in the view shown.
        window.track { [weak self] in
            guard let self else { return }
            let basic = self.model.view.basic
            stepOver.tooltip(basic ? "Step over (F6): to the next statement, running PROCs, FNs and GOSUBs through"
                : "Step over (F6): a JSR runs to the next instruction")
            stepInto.tooltip(basic ? "Step into (F7): to the next statement, into PROCs, FNs and GOSUBs"
                : "Step into (F7): one instruction")
            stepOut.tooltip(basic ? "Step out (F8): until this PROC, FN or subroutine returns"
                : "Step out (F8): until this subroutine or interrupt returns")
        }
        return header
    }

    // MARK: Content

    private func buildContent() {
        let disassembly = DisassemblyPane(model: model)
        self.disassembly = disassembly
        let memory = MemoryPane(model: model)
        self.memory = memory
        let code = Paned(.vertical, start: disassembly.root, end: memory.root, position: 420).resizes(start: true, end: true)
        code.size(width: 520)
        disassembly.root.size(height: 220)
        memory.root.size(height: 180)
        let sidebar = MachineSidebar.make(model: model).size(width: 360)
        let machineCode = Paned(.horizontal, start: code, end: sidebar, position: 1100 - 400).resizes(start: true, end: false)

        let listing = BasicListingPane(model: model)
        self.listing = listing
        let variables = BasicVariablesPane(model: model)
        self.variables = variables
        let program = Paned(.vertical, start: listing.root, end: variables.root, position: 440).resizes(start: true, end: true)
        program.size(width: 520)
        listing.root.size(height: 220)
        variables.root.size(height: 160)
        let basicSidebar = BasicSidebar.make(model: model).size(width: 360)
        let basic = Paned(.horizontal, start: program, end: basicSidebar, position: 1100 - 400).resizes(start: true, end: false)

        content.add(machineCode, name: "code")
        content.add(basic, name: "basic")
        content.visible = model.view.basic ? "basic" : "code"
    }

    // MARK: State

    private func observe() {
        let model = self.model
        window.track { [weak self] in
            guard let self else { return }
            let name = "Debugger — \(self.machine.model.displayName)"
            self.window.title = name
            self.windowTitle.title = name
            self.windowTitle.subtitle = Self.status(model.snapshot)
        }
        window.track { [weak self] in
            guard let self else { return }
            let basic = model.view.basic
            self.viewSwitch.selected = basic ? 1 : 0
            self.content.visible = basic ? "basic" : "code"
            self.cpuSwitch.isVisible = model.snapshot?.hasSecondProcessor == true && !basic
            self.cpuSwitch.selected = model.view.cpu == .parasite ? 1 : 0
            for widget in self.machineCodeOnly { widget.isVisible = !basic }
            let stopped = model.isStopped
            for name in ["step-over", "step-into", "step-out"] {
                self.actions[name]?.isEnabled = stopped
            }
            for name in ["step-back", "reverse-continue"] {
                self.actions[name]?.isEnabled = stopped && !basic
            }
            for name in ["step-cycle", "next-scanline", "next-frame", "next-interrupt"] {
                self.actions[name]?.isEnabled = !basic
            }
            // (Changed only when it changes: a tooltip shown would flicker.)
            if self.continueShows?.stopped != stopped || self.continueShows?.basic != basic {
                self.continueShows = (stopped, basic)
                self.continueButton.iconName = stopped ? "media-playback-start-symbolic" : "media-playback-pause-symbolic"
                self.continueButton.accessibleLabel(stopped ? "Continue" : "Pause")
                self.continueButton.tooltip(stopped ? "Continue (Alt+Y)"
                    : basic ? "Pause (Alt+Y): at the next BASIC statement" : "Pause (Alt+Y)")
            }
        }
    }

    /// What it's doing: stopped (and why), stepping, or running.
    static func status(_ snapshot: DebugSnapshot?) -> String {
        guard let snapshot else { return "" }
        if let reason = snapshot.stopReason {
            return "Stopped: \(reason)"
        }
        if snapshot.isRunningCommand && snapshot.view.basic {
            return "Running to a BASIC statement…"
        }
        return snapshot.isRunningCommand ? "Stepping…" : "Running"
    }
}
