import BeebCore
import BeebHost
import BeebLibrary
import BeebNetwork
import BeebROMs
import CGtk
import Foundation

/// A machine's window: its picture, header bar and menu. A standalone
/// machine's, or a network station's. (The Mac's is MachineScreen, with
/// its menu bar commands and toolbar.)
@MainActor
final class MachineWindow {
    let machine: MachineController
    let window: Window
    let emulator: EmulatorArea
    private let toasts: ToastOverlay
    private let windowTitle = WindowTitle("BBC Micro")
    private let inspection = Label("", style: "monospace", "osd")
    private var actions: [String: Action] = [:]
    /// The main menu's button (self-tests open it).
    private(set) var menuButton: MenuButton?

    /// Open machine windows, by machine.
    private(set) static var open: [ObjectIdentifier: MachineWindow] = [:]

    /// A new window with a new standalone machine.
    @discardableResult
    static func openNew() -> MachineWindow {
        let window = MachineWindow(machine: MachineController())
        window.window.present()
        return window
    }

    /// The window showing `machine`, if it has one.
    static func existing(for machine: MachineController) -> MachineWindow? {
        open[ObjectIdentifier(machine)]
    }

    /// Shows `machine` (a station's, say), in its own window.
    @discardableResult
    static func show(_ machine: MachineController) -> MachineWindow {
        if let window = existing(for: machine) {
            window.window.present()
            return window
        }
        let window = MachineWindow(machine: machine)
        window.window.present()
        return window
    }

    init(machine: MachineController) {
        self.machine = machine
        let size = Self.savedSize
        window = Window(title: "BBC Micro", width: size.width, height: size.height)
        if UserDefaults.standard.bool(forKey: Self.maximizedKey) { gtk_window_maximize(window.window) }
        emulator = EmulatorArea(host: machine.host)
        machine.renderer = emulator.renderer
        emulator.keyboardDisc = { [weak machine] in machine?.bootDiscPath }
        emulator.onHover = { [weak machine] pixel in machine?.hoveredPixel = pixel.map { (x: $0.0, y: $0.1) } }
        emulator.onZoom = { [weak machine] zoom in machine?.pictureZoomed(zoom) }

        let screen = Bin(emulator.area).style("machine-screen").expand()
        inspection.align(horizontal: GTK_ALIGN_START, vertical: GTK_ALIGN_END).margin(8).canTarget(false).visible(false)
        let inspection = self.inspection
        let overlay = Overlay(screen) { inspection }
        toasts = ToastOverlay(overlay)

        let header = HeaderBar(title: windowTitle)
        let content = ToolbarView(content: toasts).top(header)
        window.content = content
        // Full screen is the picture alone (F11 again leaves).
        window.object.onChange("fullscreened") { [window] in
            let fullscreen = window.isFullscreen
            content.revealsTopBars = !fullscreen
            content.extendContentToTop(fullscreen)
        }
        window.minimumSize(width: 368, height: 288 + 47)

        Self.open[ObjectIdentifier(machine)] = self
        buildActions()
        window.shortcuts(Self.shortcuts + App.appShortcuts)
        buildHeaderBar(header)
        observe()
        handleWindowEvents()
        installDrop()
        emulator.onMouseCapture = { [weak self] captured in
            guard let self else { return }
            if captured {
                self.toasts.show("Mouse captured: Alt+Escape releases it")
            }
            self.updateTitle()
        }
        emulator.area.grabFocus()
        // (Focus once the window's shown, too: before that it may not take.)
        window.onMap { [emulator] in emulator.area.grabFocus() }
        if ProcessInfo.processInfo.environment["MACBEEB_DEBUG_KEYS"] != nil {
            window.add(KeyController().phase(GTK_PHASE_CAPTURE).onPressed { [window] keyval, keycode, _ in
                let focus = gtk_window_get_focus(window.window).map { String(cString: gtk_widget_get_name($0)) } ?? "none"
                print("window heard keyval \(keyval) keycode \(keycode), focus \(focus)")
                return false
            })
        }
        window.keep(self)
    }

    // MARK: State

    private func observe() {
        let machine = machine
        window.track { [weak self] in self?.updateTitle() }
        window.track { [weak self] in
            guard let self else { return }
            self.emulator.renderer.style = machine.displayStyle
            self.emulator.renderer.monitor = machine.monitor
            self.emulator.redraw()
        }
        window.track { [weak self] in
            guard let self else { return }
            let text = machine.inspection
            self.inspection.text = text ?? ""
            self.inspection.isVisible = text != nil
        }
        window.track { [weak self] in
            // The debugger's open: the screen can be inspected.
            machine.host.setInspecting(machine.debugger.isVisible)
            _ = self
        }
        window.track { [weak self] in
            guard let self, let toast = machine.toast else { return }
            self.toasts.show(toast, timeout: 2)
            macbeeb_announce(self.window.widget, toast)
        }
        window.track { [weak self] in
            guard machine.debuggerRequested else { return }
            machine.debuggerRequested = false
            DebuggerWindow.show(for: machine)
            _ = self
        }
        window.track {
            guard machine.hardwareRequested else { return }
            machine.hardwareRequested = false
            HardwareExpansionsWindow.show(for: machine)
        }
        window.track {
            guard machine.discContentsRequested else { return }
            machine.discContentsRequested = false
            DiscContentsWindow.show(for: machine)
        }
        window.track {
            guard machine.bookshelfRequested else { return }
            machine.bookshelfRequested = false
            BookshelfWindow.show()
        }
        window.track { [weak self] in
            guard let self, machine.showingTimeline else { return }
            RewindDialog(machine: machine).present(over: self.window)
        }
        window.track { [weak self] in
            // The keyboard follows the disc in drive 0's own keys.
            _ = machine.bootDiscPath
            self?.emulator.updateTranslator()
        }
    }

    /// "Model B + 6502 Second Processor", and what's in drive 0, what it's
    /// doing.
    private func updateTitle() {
        var name = machine.model.displayName + (machine.fittedCoprocessor.map { " + " + $0.displayName } ?? "")
        if machine.model == .modelB {
            if machine.expansions.board != .none {
                name += " + " + machine.expansions.board.displayName
            }
            if machine.expansions.sidewaysRAM != .none {
                name += " + " + machine.expansions.sidewaysRAM.displayName
            }
        }
        if let station = machine.station {
            name = station.stationTitle(machine) + " — " + name
        }
        if machine.videoNuLA {
            name += " + VideoNuLA"
        }
        var subtitle: [String] = []
        if let disc = machine.discNames[0] { subtitle.append(disc) }
        if machine.paused {
            subtitle.append("Paused")
        } else if machine.heldForAgent {
            subtitle.append("Held by AI Agent")
        }
        if machine.recordingURL != nil { subtitle.append("● Recording") }
        if emulator.mouseCaptured { subtitle.append("Mouse captured: Alt+Escape releases it") }
        windowTitle.title = name
        windowTitle.subtitle = subtitle.joined(separator: " · ")
        window.title = ([name] + (machine.discNames[0].map { [$0] } ?? [])).joined(separator: " — ")
    }

    // MARK: The window's size, remembered (as GNOME's apps do)

    private static let sizeKey = "MacBeebMachineWindowSize"
    private static let maximizedKey = "MacBeebMachineWindowMaximized"

    private static var savedSize: (width: Int32, height: Int32) {
        let saved = UserDefaults.standard.array(forKey: sizeKey) as? [Int] ?? []
        guard saved.count == 2, saved[0] >= 368, saved[1] >= 288 else { return (960, 768 + 47) }
        return (Int32(saved[0]), Int32(saved[1]))
    }

    private func rememberSize() {
        let maximized = window.isMaximized
        UserDefaults.standard.set(maximized, forKey: Self.maximizedKey)
        guard !maximized, !window.isFullscreen else { return }
        let size = window.defaultSize
        UserDefaults.standard.set([Int(size.width), Int(size.height)], forKey: Self.sizeKey)
    }

    private func handleWindowEvents() {
        let machine = machine
        window.onCloseRequest { [weak self] in
            self?.rememberSize()
            return false
        }
        window.onActiveChanged { [weak self] active in
            guard let self else { return }
            if active {
                Joysticks.shared.machine = machine
                if !machine.isStation {
                    MachineController.frontmost = machine
                }
                App.noteActive()
            } else {
                self.emulator.setMouseCaptured(false)
                self.emulator.releaseAll()
            }
        }
        window.onDestroy { [weak self] in
            guard let self else { return }
            Self.open[ObjectIdentifier(machine)] = nil
            machine.renderer = nil
            // A station runs on without its window.
            guard !machine.isStation else { return }
            // Closed (the library may keep the app open): it stops, and
            // the library stops using it.
            machine.setPaused(true)
            if MachineController.frontmost === machine {
                MachineController.frontmost = nil
            }
            _ = self
        }
        let center = NotificationCenter.default
        let zoom = center.addObserver(forName: MachineWindowEvent.setZoom, object: nil, queue: .main) { [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            let zoom = note.userInfo?["zoom"] as? Double
            MainActor.assumeIsolated {
                guard let self, sender == ObjectIdentifier(machine.host), let zoom else { return }
                self.applyZoom(zoom)
            }
        }
        let front = center.addObserver(forName: MachineWindowEvent.bringToFront, object: nil, queue: .main) { [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, sender == ObjectIdentifier(machine.host) else { return }
                self.window.present()
                self.emulator.area.grabFocus()
            }
        }
        window.onDestroy {
            center.removeObserver(zoom)
            center.removeObserver(front)
        }
    }

    /// Resizes the window so the picture is `zoom` times its actual size.
    private func applyZoom(_ zoom: Double) {
        guard !window.isFullscreen else { return }
        let chromeWidth = Double(window.width - emulator.area.width)
        let chromeHeight = Double(window.height - emulator.area.height)
        var height = EmulatorArea.actualHeight * zoom
        // As big as fits on the monitor, if that's less.
        if let surface = gtk_native_get_surface(cast(window.widget)),
           let monitor = gdk_display_get_monitor_at_surface(gdk_display_get_default(), surface) {
            var area = GdkRectangle()
            gdk_monitor_get_geometry(monitor, &area)
            height = min(height, Double(area.height) - chromeHeight - 48, (Double(area.width) - chromeWidth) / Renderer.aspect)
        }
        let width = (height * Renderer.aspect).rounded()
        if window.isMaximized { gtk_window_unmaximize(window.window) }
        window.setDefaultSize(width: Int32(width + chromeWidth), height: Int32(height.rounded() + chromeHeight))
    }

    // MARK: Drops

    private func installDrop() {
        emulator.area.onDropFiles { [weak self] urls, _, _ in
            guard let self, let url = urls.first else { return false }
            return self.open(url)
        }
    }

    /// Opens a file dropped on the window, or opened with the app.
    @discardableResult
    func open(_ url: URL) -> Bool {
        if JoinRequests.isJoinLink(url) {
            JoinRequests.shared.handle(url)
            JoinRoomWindow.show()
            return true
        }
        switch url.pathExtension.lowercased() {
        case NetworkPackage.fileExtension:
            NetworkStudioWindow.show(url)
        case _ where Disc.ImageFormat(path: url.path) != nil:
            machine.insertDisc(url)
        case "uef", "csw":
            machine.insertTape(url)
        case "bas":
            machine.runBASICProgram(url)
        case SaveStateFile.fileExtension:
            machine.loadState(url)
        default:
            return false
        }
        window.present()
        return true
    }

    // MARK: Actions

    /// A command, enabled as `enabled` says (followed as it changes).
    private func command(_ name: String, enabled: (@MainActor () -> Bool)? = nil, _ body: @escaping @MainActor () -> Void) {
        let action = window.action(name, body)
        actions[name] = action
        if let enabled {
            window.track { action.isEnabled = enabled() }
        }
    }

    private func toggle(_ name: String, isOn: @escaping @MainActor () -> Bool, enabled: (@MainActor () -> Bool)? = nil,
                        _ set: @escaping @MainActor (Bool) -> Void) {
        let action = window.add(Action(toggle: name, isOn: isOn(), set))
        actions[name] = action
        window.track {
            action.isOn = isOn()
            if let enabled { action.isEnabled = enabled() }
        }
    }

    private func choice(_ name: String, value: @escaping @MainActor () -> String, enabled: (@MainActor () -> Bool)? = nil,
                        _ set: @escaping @MainActor (String) -> Void) {
        let action = window.add(Action(choice: name, value: value(), set))
        actions[name] = action
        window.track {
            action.value = value()
            if let enabled { action.isEnabled = enabled() }
        }
    }

    private func buildActions() {
        let machine = machine
        let hasDiscs: @MainActor () -> Bool = { machine.model.hasDiscInterface }

        // Discs and tapes.
        command("new-disc", enabled: hasDiscs) { machine.newDisc() }
        command("open-disc", enabled: hasDiscs) { machine.openDisc() }
        command("insert-drive-0") { machine.openDisc(drive: 0, boot: false) }
        command("insert-drive-1") { machine.openDisc(drive: 1, boot: false) }
        choice("insert-bundled", value: { "" }, enabled: hasDiscs) { value in
            let parts = value.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let drive = Int(parts[0]),
                  let disc = BeebROMs.BundledDisc(rawValue: String(parts[1])) else { return }
            machine.insertBundledDisc(disc, drive: drive)
        }
        choice("open-recent", value: { "" }, enabled: hasDiscs) { path in
            machine.openRecentDisc(URL(fileURLWithPath: path))
        }
        command("clear-recent", enabled: { !RecentDiscs.shared.urls.isEmpty }) { RecentDiscs.shared.clear() }
        command("disc-contents", enabled: hasDiscs) { machine.discContentsRequested = true }
        command("eject-0", enabled: { machine.discNames[0] != nil }) { machine.ejectDisc(drive: 0) }
        command("eject-1", enabled: { machine.discNames[1] != nil }) { machine.ejectDisc(drive: 1) }
        command("load-tape", enabled: { machine.model.hasCassette }) { machine.openTape() }
        command("rewind-tape", enabled: { machine.tapeName != nil }) { machine.rewindTape() }
        command("eject-tape", enabled: { machine.tapeName != nil }) { machine.ejectTape() }

        // Saving.
        command("screenshot") { machine.saveScreenshot() }
        command("copy-screen") { machine.copyScreenshot() }
        command("paste-text") { machine.pasteText() }
        command("save-state") { machine.saveState() }
        command("load-state") { machine.loadState() }
        command("quick-save", enabled: { machine.snapshotOwner != nil && !machine.snapshotBusy }) { machine.quickSave() }
        command("quick-load", enabled: { !machine.snapshotHistory.isEmpty && !machine.snapshotBusy }) { machine.quickLoad() }
        choice("load-snapshot", value: { "" }) { id in
            if let snapshot = machine.snapshotHistory.first(where: { $0.id.uuidString == id }) {
                machine.quickLoad(snapshot)
            }
        }
        command("record") { machine.toggleRecording() }

        // The machine.
        command("pause") { machine.togglePause() }
        toggle("full-speed", isOn: { !machine.speedLimited }) { _ in machine.toggleSpeedLimit() }
        command("break") { machine.pressBreak() }
        command("shift-break") { machine.shiftBreak() }
        command("ctrl-break") { machine.ctrlBreak() }
        command("power-cycle") { machine.powerCycle() }
        toggle("drive-sounds", isOn: { machine.discDriveSounds }) { machine.setDiscDriveSounds($0) }
        command("disc-controls", enabled: { machine.bootDiscPath != nil }) {
            KeyboardSettings.shared.editingDisc = machine.bootDiscPath
            PreferencesWindow.show(page: .keyboard)
        }
        command("capture-mouse", enabled: { machine.model != .masterCompact }) { machine.toggleMouseCapture() }
        command("rewind") { machine.rewind(seconds: 5) }
        choice("rewind-by", value: { "" }) { seconds in machine.rewind(seconds: Double(seconds) ?? 5) }
        command("timeline") { machine.showingTimeline = true }
        choice("model", value: { machine.model.rawValue }) { value in
            if let model = BBCMicro.Model(rawValue: value) { machine.setModel(model) }
        }
        choice("coprocessor", value: { machine.fittedCoprocessor?.rawValue ?? "none" },
               enabled: { machine.model.hasTube }) { value in
            machine.setCoprocessor(BBCMicro.Coprocessor(rawValue: value))
        }
        choice("disc-interface", value: { machine.discInterface.rawValue },
               enabled: { machine.model == .modelB }) { value in
            if let interface = BBCMicro.DiscInterface(rawValue: value) { machine.setDiscInterface(interface) }
        }
        command("hardware") { machine.hardwareRequested = true }
        choice("configuration", value: { MachineConfigurations.shared.matching(machine.setup)?.id.uuidString ?? "" }) { id in
            if let saved = UUID(uuidString: id).flatMap({ MachineConfigurations.shared[$0] }) {
                machine.use(saved.setup)
            }
        }
        command("save-configuration") { [weak self] in
            guard let self else { return }
            MachineConfigurationsWindow.save(machine.setup, over: self.window)
        }
        command("new-configuration") { MachineConfigurationsWindow.newConfiguration() }

        // The display.
        choice("display", value: { machine.displayStyle.rawValue }) { value in
            if let style = DisplayStyle(rawValue: value) { machine.displayStyle = style }
        }
        choice("monitor", value: { machine.monitor.rawValue }) { value in
            if let monitor = Monitor(rawValue: value) { machine.monitor = monitor }
        }
        choice("zoom", value: { machine.zoom.map { "\(Int(($0 * 100).rounded()))" } ?? "" }) { value in
            if let percent = Double(value) { machine.setZoom(percent / 100) }
        }
        command("actual-size") { machine.setZoom(1) }
        command("zoom-in") { machine.zoom(in: true) }
        command("zoom-out") { machine.zoom(in: false) }
        command("fullscreen") { [weak self] in
            guard let self else { return }
            self.window.isFullscreen.toggle()
        }

        // Debugging.
        command("debugger") { machine.debuggerRequested = true }
        command("break-into-debugger") {
            machine.debugger.pauseOrContinue()
            machine.debuggerRequested = machine.debugStop == nil
        }

        command("close") { [weak self] in self?.window.close() }
    }

    /// The window's keyboard shortcuts. Alt plays the Mac's Command key's
    /// part (the BBC has neither, so Control stays the BBC's own).
    static let shortcuts: [(action: String, accels: [String])] = [
        ("win.new-disc", ["<Alt>n"]),
        ("win.open-disc", ["<Alt>o"]),
        ("win.insert-drive-0", ["<Alt><Shift>o"]),
        ("win.disc-contents", ["<Alt><Shift>i"]),
        ("win.load-tape", ["<Alt>t"]),
        ("win.screenshot", ["<Alt>s"]),
        ("win.copy-screen", ["<Alt>c"]),
        ("win.paste-text", ["<Alt>v"]),
        ("win.save-state", ["<Alt><Shift>s"]),
        ("win.load-state", ["<Alt><Shift>l"]),
        ("win.quick-save", ["<Alt><Shift>F6"]),
        ("win.quick-load", ["<Alt><Shift>F5"]),
        ("win.record", ["<Alt>r"]),
        ("win.pause", ["<Alt>p"]),
        ("win.full-speed", ["<Alt>f"]),
        ("win.break", ["<Alt>b"]),
        ("win.shift-break", ["<Alt><Shift>b"]),
        ("win.ctrl-break", ["<Alt><Control>b"]),
        ("win.power-cycle", ["<Alt><Shift>r"]),
        ("win.capture-mouse", ["<Alt>m"]),
        ("win.rewind", ["<Alt>Left"]),
        ("win.timeline", ["<Alt><Shift>Left"]),
        ("win.hardware", ["<Alt>e"]),
        ("win.actual-size", ["<Alt>0"]),
        ("win.zoom-in", ["<Alt>equal", "<Alt>plus"]),
        ("win.zoom-out", ["<Alt>minus"]),
        ("win.fullscreen", ["F11"]),
        ("win.debugger", ["<Alt>d"]),
        ("win.break-into-debugger", ["<Alt>y"]),
        ("win.close", ["<Alt>w"]),
    ]

    // MARK: The header bar

    private func buildHeaderBar(_ header: HeaderBar) {
        let machine = machine

        // Start: the machine, the games, discs and tapes.
        let model = MenuButton(icon: "computer-symbolic", menu: Self.modelMenu())
            .tooltip("Choose the machine (power cycles)")
        let games = Button(icon: "applications-games-symbolic") { BookshelfWindow.show() }
            .tooltip("The game library: BBC Micro Classics from BBCMicro.co.uk, and your own games")
        let disc = SplitButton(icon: "media-floppy-symbolic", menu: Menu {
            MenuSection {
                MenuItem("Open and Boot Disc…", "win.open-disc")
                MenuItem("Insert in Drive 0…", "win.insert-drive-0")
                MenuItem("Insert in Drive 1…", "win.insert-drive-1")
                MenuItem("New Disc…", "win.new-disc")
                MenuItem("Show Disc Contents", "win.disc-contents")
            }
            MenuSection {
                MenuItem("Eject Drive 0", "win.eject-0")
                MenuItem("Eject Drive 1", "win.eject-1")
            }
        }) { machine.openDisc() }
            .tooltip("Open and boot a disc")
        let tape = SplitButton(icon: "media-tape-symbolic", menu: Menu {
            MenuItem("Load Tape…", "win.load-tape")
            MenuItem("Rewind Tape", "win.rewind-tape")
            MenuItem("Eject Tape", "win.eject-tape")
        }) { machine.openTape() }
            .tooltip("Load a tape")
        header.start(model).start(games).start(disc).start(tape)
        window.track {
            disc.isEnabled = machine.model.hasDiscInterface
            tape.isEnabled = machine.model.hasCassette
        }

        // End (packed from the right): the menu, the lights, then the
        // machine's controls.
        // The menu's lists that change: recent discs, and the quick saves of
        // the disc in the drive.
        let recent = Menu {}
        window.track {
            recent.set([MenuSection {
                for url in RecentDiscs.shared.urls {
                    MenuItem(url.lastPathComponent, "win.open-recent", target: url.path)
                }
            }, MenuItem("Clear Menu", "win.clear-recent")])
        }
        let snapshots = Menu {}
        window.track {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            guard let owner = machine.snapshotOwner else {
                snapshots.set([MenuItem("Put a disc in to take snapshots", "win.none")])
                return
            }
            let history = machine.snapshotHistory
            snapshots.set(history.isEmpty
                ? [MenuItem("No snapshots of “\(owner.name)” yet", "win.none")]
                : history.enumerated().map { index, snapshot in
                    MenuItem("\(index + 1). \(formatter.string(from: snapshot.created))", "win.load-snapshot",
                             target: snapshot.id.uuidString)
                })
        }
        // The saved machines (not observable: refreshed as the menu opens).
        let configurations = Menu {}
        let refreshConfigurations = { [weak self] in
            configurations.set(MachineConfigurations.shared.machines.map {
                MenuItem($0.name, "win.configuration", target: $0.id.uuidString)
            } + [MenuSection {
                MenuItem("Save Configuration…", "win.save-configuration")
                MenuItem("New Configuration…", "win.new-configuration")
                MenuItem("Manage Configurations…", "app.machine-configurations")
            }])
            self?.actions["configuration"]?.value = MachineConfigurations.shared.matching(machine.setup)?.id.uuidString ?? ""
        }
        refreshConfigurations()
        let menu = MenuButton(icon: "open-menu-symbolic",
                              menu: Self.mainMenu(recent: recent, snapshots: snapshots, configurations: configurations))
            .tooltip("Main Menu")
        menuButton = menu
        if let popover = gtk_menu_button_get_popover(cast(menu.widget)) {
            GObjectRef(popover).on("show") { refreshConfigurations() }
        }
        let lights = MachineLights(machine: machine)
        let agent = AgentLight(machine: machine)
        let record = Button(icon: "media-record-symbolic") { machine.toggleRecording() }
        let screenshot = Button(icon: "camera-photo-symbolic") { machine.saveScreenshot() }
            .tooltip("Save a screenshot")
        let speed = ToggleButton(icon: "power-profile-performance-symbolic") { on in
            if on == machine.speedLimited { machine.toggleSpeedLimit() }
        }
        .tooltip("Run as fast as possible")
        let pause = Button(icon: "media-playback-pause-symbolic") { machine.togglePause() }
        let rewind = SplitButton(icon: "media-seek-backward-symbolic", menu: Menu {
            MenuSection {
                MenuItem("Back 1 Second", "win.rewind-by", target: "1")
                MenuItem("Back 5 Seconds", "win.rewind-by", target: "5")
                MenuItem("Back 30 Seconds", "win.rewind-by", target: "30")
            }
            MenuItem("Timeline…", "win.timeline")
        }) { machine.rewind(seconds: 5) }
            .tooltip("Go back 5 seconds")
        let power = Button(icon: "system-shutdown-symbolic") { machine.powerCycle() }
            .tooltip("Switch off and on again")
        let breakButton = Button(icon: "object-rotate-left-symbolic") { machine.pressBreak() }
            .tooltip("Break")
        header.end(menu).end(lights.widget).end(agent.widget).end(record).end(screenshot).end(speed)
            .end(pause).end(rewind).end(power).end(breakButton)

        window.track {
            let still = machine.isStill
            pause.iconName = still ? "media-playback-start-symbolic" : "media-playback-pause-symbolic"
            pause.tooltip(machine.heldForAgent && !machine.paused
                          ? "Resume (an AI agent is holding the machine between its tool calls)"
                          : still ? "Resume" : "Pause")
            speed.isOn = !machine.speedLimited
            let recording = machine.recordingURL != nil
            record.iconName = recording ? "media-playback-stop-symbolic" : "media-record-symbolic"
            record.setStyle("destructive-action", recording)
            record.tooltip(recording ? "Stop recording" : "Record a video")
        }

        // Narrow windows keep the essentials.
        let medium = macbeeb_breakpoint("max-width: 860sp")!
        for widget in [lights.widget.widget, record.widget, screenshot.widget, speed.widget, tape.widget] {
            macbeeb_breakpoint_hide(medium, widget)
        }
        adw_application_window_add_breakpoint(cast(window.widget), medium)
        let narrow = macbeeb_breakpoint("max-width: 600sp")!
        for widget in [lights.widget.widget, record.widget, screenshot.widget, speed.widget, tape.widget, games.widget,
                       rewind.widget, power.widget] {
            macbeeb_breakpoint_hide(narrow, widget)
        }
        adw_application_window_add_breakpoint(cast(window.widget), narrow)
    }

    static func modelMenu() -> Menu {
        Menu {
            MenuSection("Model") {
                for model in BBCMicro.Model.allCases {
                    MenuItem(model.displayName, "win.model", target: model.rawValue)
                }
            }
            MenuSection("Second Processor") {
                MenuItem("No Second Processor", "win.coprocessor", target: "none")
                for coprocessor in BBCMicro.Coprocessor.allCases {
                    MenuItem(coprocessor.displayName, "win.coprocessor", target: coprocessor.rawValue)
                }
            }
            MenuSection {
                MenuItem("Hardware…", "win.hardware", accel: "<Alt>e")
            }
        }
    }

    /// The primary menu: the Mac's menu bar, menu by menu.
    static func mainMenu(recent: Menu, snapshots: Menu, configurations: Menu) -> Menu {
        Menu {
            MenuSection {
                MenuItem("New BBC Micro Window", "app.new-window", accel: "<Alt><Control>n")
                MenuItem("Game Library", "app.library", accel: "<Alt><Shift>k")
                MenuItem("Welcome to MacBeeb", "app.welcome", accel: "<Alt><Shift>1")
            }
            MenuSection {
                Submenu("Disc") {
                    MenuSection {
                        MenuItem("New Disc…", "win.new-disc", accel: "<Alt>n")
                        MenuItem("Open Disc…", "win.open-disc", accel: "<Alt>o")
                        Submenu("Open Recent Disc", live: recent)
                        MenuItem("Insert in Drive 0…", "win.insert-drive-0", accel: "<Alt><Shift>o")
                        MenuItem("Insert in Drive 1…", "win.insert-drive-1")
                        for drive in 0..<2 {
                            Submenu("Insert Bundled Disc in Drive \(drive)") {
                                for disc in BeebROMs.BundledDisc.allCases {
                                    MenuItem(disc.displayName, "win.insert-bundled", target: "\(drive):\(disc.rawValue)")
                                }
                            }
                        }
                    }
                    MenuSection {
                        MenuItem("Show Disc Contents", "win.disc-contents", accel: "<Alt><Shift>i")
                    }
                    MenuSection {
                        MenuItem("Eject Drive 0", "win.eject-0")
                        MenuItem("Eject Drive 1", "win.eject-1")
                    }
                }
                Submenu("Tape") {
                    MenuItem("Load Tape…", "win.load-tape", accel: "<Alt>t")
                    MenuItem("Rewind Tape", "win.rewind-tape")
                    MenuItem("Eject Tape", "win.eject-tape")
                }
                Submenu("Save and Load") {
                    MenuSection {
                        MenuItem("Save Screenshot…", "win.screenshot", accel: "<Alt>s")
                        MenuItem("Copy Screenshot", "win.copy-screen", accel: "<Alt>c")
                        MenuItem("Paste Text into BBC", "win.paste-text", accel: "<Alt>v")
                    }
                    MenuSection {
                        MenuItem("Save State…", "win.save-state", accel: "<Alt><Shift>s")
                        MenuItem("Load State…", "win.load-state", accel: "<Alt><Shift>l")
                    }
                    MenuSection {
                        MenuItem("Quick Save", "win.quick-save", accel: "<Alt><Shift>F6")
                        MenuItem("Quick Load", "win.quick-load", accel: "<Alt><Shift>F5")
                        Submenu("Snapshots", live: snapshots)
                    }
                    MenuSection {
                        MenuItem("Start or Stop Recording…", "win.record", accel: "<Alt>r")
                    }
                }
                Submenu("Machine") {
                    MenuSection {
                        MenuItem("Pause or Resume", "win.pause", accel: "<Alt>p")
                        MenuItem("Full Speed", "win.full-speed", accel: "<Alt>f")
                    }
                    MenuSection {
                        MenuItem("Break", "win.break", accel: "<Alt>b")
                        MenuItem("Shift-Break (Boot Disc)", "win.shift-break", accel: "<Alt><Shift>b")
                        MenuItem("Ctrl-Break (Hard Reset)", "win.ctrl-break", accel: "<Alt><Control>b")
                        MenuItem("Power Cycle", "win.power-cycle", accel: "<Alt><Shift>r")
                    }
                    MenuSection {
                        MenuItem("Disc Drive Sounds", "win.drive-sounds")
                        MenuItem("Controls for This Disc…", "win.disc-controls")
                        MenuItem("Capture or Release Mouse", "win.capture-mouse", accel: "<Alt>m")
                    }
                    MenuSection {
                        MenuItem("Rewind 5 Seconds", "win.rewind", accel: "<Alt>Left")
                        MenuItem("Rewind Timeline…", "win.timeline", accel: "<Alt><Shift>Left")
                    }
                    MenuSection {
                        Submenu("Model") {
                            for model in BBCMicro.Model.allCases {
                                MenuItem(model.displayName, "win.model", target: model.rawValue)
                            }
                        }
                        Submenu("Second Processor") {
                            MenuItem("None", "win.coprocessor", target: "none")
                            for coprocessor in BBCMicro.Coprocessor.allCases {
                                MenuItem(coprocessor.displayName, "win.coprocessor", target: coprocessor.rawValue)
                            }
                        }
                        Submenu("Disc Interface") {
                            for interface in BBCMicro.DiscInterface.allCases {
                                MenuItem(interface.displayName, "win.disc-interface", target: interface.rawValue)
                            }
                        }
                        MenuItem("Hardware…", "win.hardware", accel: "<Alt>e")
                        MenuItem("ROM Library…", "app.rom-library")
                        Submenu("Machine Configurations", live: configurations)
                    }
                }
                Submenu("View") {
                    MenuSection("Display") {
                        for style in DisplayStyle.allCases {
                            MenuItem(style.name, "win.display", target: style.rawValue)
                        }
                    }
                    MenuSection("Monitor") {
                        for monitor in Monitor.allCases {
                            MenuItem(monitor.name, "win.monitor", target: monitor.rawValue)
                        }
                    }
                    MenuSection("Zoom") {
                        for level in MachineController.zoomLevels {
                            MenuItem("\(Int(level * 100))%", "win.zoom", target: "\(Int(level * 100))")
                        }
                    }
                    MenuSection {
                        MenuItem("Actual Size", "win.actual-size", accel: "<Alt>0")
                        MenuItem("Zoom In", "win.zoom-in", accel: "<Alt>equal")
                        MenuItem("Zoom Out", "win.zoom-out", accel: "<Alt>minus")
                        MenuItem("Full Screen", "win.fullscreen", accel: "F11")
                    }
                }
                Submenu("Debug") {
                    MenuSection {
                        MenuItem("Show Debugger", "win.debugger", accel: "<Alt>d")
                        MenuItem("Break into Debugger or Continue", "win.break-into-debugger", accel: "<Alt>y")
                    }
                    MenuSection {
                        MenuItem("Debugging with VS Code Guide", "app.guide", target: "vscode")
                        MenuItem("Get the VS Code Extension", "app.vscode-extension")
                    }
                }
                Submenu("Network") {
                    MenuItem("New Network…", "app.new-network", accel: "<Alt><Shift>n")
                    MenuItem("Open Network…", "app.open-network")
                    MenuItem("Join Econet Network…", "app.join-network", accel: "<Alt><Shift>j")
                    MenuItem("Add Remote Elite…", "app.add-remote-elite")
                    MenuItem("Network Studio", "app.network-studio", accel: "<Alt><Control>0")
                    MenuItem("Print Centre", "app.print-centre", accel: "<Alt><Control>p")
                }
                Submenu("AI Agents") {
                    MenuItem("Connect an AI Agent…", "app.connect-agent")
                    MenuItem("Activity Log", "app.agent-log", accel: "<Alt><Control>l")
                }
            }
            MenuSection {
                MenuItem("Preferences", "app.preferences", accel: "<Alt>comma")
                MenuItem("Keyboard Shortcuts", "app.shortcuts", accel: "<Alt>question")
                Submenu("Help") {
                    MenuItem("What’s New in MacBeeb", "app.whats-new")
                    MenuItem("Hardware Expansion Guide", "app.guide", target: "README")
                    MenuItem("Credits", "app.credits")
                    MenuItem("Check for Updates…", "app.check-updates")
                }
                MenuItem("About MacBeeb", "app.about")
            }
        }
    }
}

/// The BBC's keyboard lights, the cassette motor and the drive lights:
/// a light over each label, as on the Mac's toolbar.
@MainActor
final class MachineLights {
    let widget: Widget
    private static let font = "Sans Bold 6"
    private static let gap = 10.0

    init(machine: MachineController) {
        let area = DrawingArea(width: 150, height: 30) { _, _, _ in }
        widget = area
        area.tooltip("Caps Lock, Shift Lock, cassette motor, drives 0 and 1")
        area.align(vertical: GTK_ALIGN_CENTER).margin(horizontal: 4)
        // (Wrappers don't own their widgets: the area's draw function can
        // hold its own.)
        area.setDraw { [area] cairo, width, _ in
            let lights = machine.lights
            let items: [(String, Bool, UInt32)] = [
                ("CAPS", lights.capsLock, 0xFF3B30), ("SHIFT", lights.shiftLock, 0xFF3B30),
                ("MOTOR", lights.cassetteMotor, 0xFF3B30), ("0", lights.drives[0], 0xFF9500),
                ("1", lights.drives[1], 0xFF9500),
            ]
            let widths = items.map { max(10, cairo.measure($0.0, font: Self.font).width) }
            let total = widths.reduce(0, +) + Self.gap * Double(items.count - 1)
            var x = (width - total) / 2
            for ((label, on, colour), labelWidth) in zip(items, widths) {
                let centre = x + labelWidth / 2
                if on {
                    cairo.color(hex: colour, alpha: 0.35)
                    cairo.circle(centre, 9, radius: 6)
                    cairo.fill()
                    cairo.color(hex: colour)
                } else {
                    cairo.foreground(of: area, alpha: 0.25)
                }
                cairo.circle(centre, 9, radius: 3.5)
                cairo.fill()
                cairo.foreground(of: area, alpha: 0.55)
                cairo.text(label, x: x + (labelWidth - cairo.measure(label, font: Self.font).width) / 2, y: 15,
                           font: Self.font)
                x += labelWidth + Self.gap
            }
        }
        area.track { [area] in
            _ = machine.lights
            area.queueDraw()
        }
        area.track { [area] in
            let lights = machine.lights
            let on = [("Caps Lock", lights.capsLock), ("Shift Lock", lights.shiftLock),
                      ("cassette motor", lights.cassetteMotor), ("drive 0", lights.drives[0]),
                      ("drive 1", lights.drives[1])].filter(\.1).map(\.0)
            area.accessibleLabel(on.isEmpty ? "Machine lights: all off" : "Machine lights on: " + on.joined(separator: ", "))
        }
    }
}

/// Lit while an AI agent's attached to this machine (with macbeeb-mcp
/// --attach), and pulsing while it's running a tool. Opens the MCP
/// activity log.
@MainActor
final class AgentLight {
    let widget: Widget

    init(machine: MachineController) {
        let dot = DrawingArea(width: 26, height: 30) { _, _, _ in }
        let button = Button(child: dot) { AgentWindows.showLog() }.style("flat")
        widget = button
        var bright = true
        dot.setDraw { [dot] cairo, width, _ in
            let busy = AgentLog.shared.callsRunning > 0
            if busy && bright {
                cairo.color(hex: 0x34C759, alpha: 0.35)
                cairo.circle(width / 2, 9, radius: 6)
                cairo.fill()
            }
            cairo.color(hex: 0x34C759, alpha: busy ? (bright ? 1 : 0.45) : 0.6)
            cairo.circle(width / 2, 9, radius: 3.5)
            cairo.fill()
            cairo.foreground(of: dot, alpha: 0.55)
            let size = cairo.measure("MCP", font: "Sans Bold 6")
            cairo.text("MCP", x: (width - size.width) / 2, y: 15, font: "Sans Bold 6")
        }
        button.track { [button, dot] in
            let log = AgentLog.shared
            let attached = machine.servesAgents && log.connections > 0
            button.isVisible = attached
            button.tooltip(log.connections == 1 ? "An AI agent is attached (click for the activity log)"
                                                : "\(log.connections) AI agents are attached (click for the activity log)")
            button.accessibleLabel(log.callsRunning > 0 ? "AI agent attached, working" : "AI agent attached")
            dot.queueDraw()
        }
        // The pulse while a tool runs.
        dot.onTick { [dot] time in
            guard AgentLog.shared.callsRunning > 0 else { return true }
            let next = (time / 400_000) % 2 == 0
            if next != bright {
                bright = next
                dot.queueDraw()
            }
            return true
        }
    }
}
