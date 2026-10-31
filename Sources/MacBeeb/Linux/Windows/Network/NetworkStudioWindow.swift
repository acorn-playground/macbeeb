import BeebCore
import BeebNetwork
import CGtk
import Foundation

/// A network's window (Window > Network Studio): its machines on the
/// canvas, side by side in tiles or one large in focus, its traffic, and
/// the Distributed Mandelbrot as it's drawn; the inspector for what's
/// selected beside them.
@MainActor
enum NetworkStudioWindow {
    /// Opens the network at `url`, or brings its window forward.
    static func show(_ url: URL) {
        NetworkStudioCommands.installObservers()
        if let studio = existing(url) {
            studio.window.present()
            return
        }
        do {
            let session = try NetworkSession.session(for: url)
            let studio = NetworkStudio(session: session)
            studio.window.present()
        } catch {
            RecentNetworks.shared.remove(url)
            showError("\(error)", for: url)
        }
    }

    /// The studio showing the network at `url` (or that was there).
    static func existing(_ url: URL) -> NetworkStudio? {
        guard let session = NetworkSession.existing(url) else { return nil }
        return NetworkStudio.open[ObjectIdentifier(session)]
    }

    private static func showError(_ message: String, for url: URL) {
        Windows.show("network-error-\(url.path)") {
            let window = Window(title: url.deletingPathExtension().lastPathComponent, width: 760, height: 520)
            window.content = ToolbarView(content: StatusPage(icon: "dialog-warning-symbolic", title: "Can’t Open the Network",
                                                             description: message)).top(HeaderBar())
            App.addStandardShortcuts(to: window)
            return window
        }
    }
}

@MainActor
final class NetworkStudio {
    enum Mode: String, CaseIterable {
        case canvas, tiles, focus, traffic, mandelbrot

        var title: String {
            switch self {
            case .canvas: "Canvas"
            case .tiles: "Tiles"
            case .focus: "Focus"
            case .traffic: "Traffic"
            case .mandelbrot: "Mandelbrot"
            }
        }

        var icon: String {
            switch self {
            case .canvas: "network-workgroup-symbolic"
            case .tiles: "view-grid-symbolic"
            case .focus: "view-dual-symbolic"
            case .traffic: "network-transmit-receive-symbolic"
            case .mandelbrot: "view-app-grid-symbolic"
            }
        }
    }

    /// The studios open, by session.
    fileprivate(set) static var open: [ObjectIdentifier: NetworkStudio] = [:]

    let session: NetworkSession
    let window: Window
    private let stack = ViewStack()
    private(set) var canvas: NetworkCanvasView?
    private let split: NetworkSplitView
    private let windowTitle = WindowTitle("Network")
    /// Follows the Distributed Mandelbrot demo once its view's been shown.
    let mandelbrot = MandelbrotFeed()
    /// A new network's window closing: it's been kept or deleted, so it may.
    private var mayClose = false
    private var askingToKeep = false
    private var lastSaveError: String?

    init(session: NetworkSession) {
        NetworkStyles.install()
        self.session = session
        window = Window(title: session.project.name, width: 1280, height: 820)
        window.minimumSize(width: 760, height: 520)

        let inspectorBox = Bin()
        split = NetworkSplitView(content: Bin(), sidebar: inspectorBox)
        split.sidebarWidth(minimum: 280, maximum: 340, fraction: 0.26)
        adw_overlay_split_view_set_pin_sidebar(cast(split.widget), 1)

        let open: (UUID) -> Void = { [session] id in
            StationWindow.show(network: session.url, node: id)
        }
        let debugger: (UUID) -> Void = { [session] id in
            if let controller = session.controllers[id] { DebuggerWindow.show(for: controller) }
        }
        let hardware: (UUID) -> Void = { [session] id in
            // On or off: while it's off, the window sets up the network's copy.
            HardwareExpansionsWindow.show(ref: .station(network: session.url, node: id))
        }

        // Each view as wide as it needs, not as wide as the widest.
        adw_view_stack_set_hhomogeneous(cast(stack.widget), 0)
        adw_view_stack_set_vhomogeneous(cast(stack.widget), 0)
        let canvas = NetworkCanvasView(session: session, openStation: open, openDebugger: debugger, openHardware: hardware)
        self.canvas = canvas
        stack.add(canvas.root, name: Mode.canvas.rawValue, title: Mode.canvas.title, icon: Mode.canvas.icon)
        stack.add(NetworkTilesView(session: session, openStation: open).root, name: Mode.tiles.rawValue,
                  title: Mode.tiles.title, icon: Mode.tiles.icon)
        stack.add(NetworkFocusView(session: session, openStation: open).root, name: Mode.focus.rawValue,
                  title: Mode.focus.title, icon: Mode.focus.icon)
        stack.add(NetworkTrafficView.make(session: session), name: Mode.traffic.rawValue,
                  title: Mode.traffic.title, icon: Mode.traffic.icon)
        stack.add(NetworkMandelbrotView(session: session, feed: mandelbrot).root, name: Mode.mandelbrot.rawValue,
                  title: Mode.mandelbrot.title, icon: Mode.mandelbrot.icon)

        // Station numbers the network's Internet room refused, and a way
        // out, wherever you're looking.
        let conflicts = Clamp(RoomConflictsView.make(session: session), maximum: 640)
        conflicts.align(horizontal: GTK_ALIGN_FILL, vertical: GTK_ALIGN_START).margin(top: 12, start: 12, end: 12)
        let content = Overlay(stack.expand()) { conflicts }
        adw_overlay_split_view_set_content(cast(split.widget), content.widget)
        let inspector = NetworkInspectorPanel(session: session, openStation: open, openDebugger: debugger, openHardware: hardware)
        inspectorBox.child = inspector.root

        let header = HeaderBar(title: windowTitle)
        window.content = ToolbarView(content: split).top(header)
        Self.open[ObjectIdentifier(session)] = self

        buildActions()
        buildHeader(header)
        observe()
        handleClosing()
        App.addStandardShortcuts(to: window)
        window.shortcut("<Alt>w", action: "window.close")
        window.keep(self)
        stack.visible = Mode.canvas.rawValue
    }

    /// Shows a view.
    func show(_ mode: Mode) {
        stack.visible = mode.rawValue
    }

    // MARK: State

    private func observe() {
        let session = session
        // The speed changes all the time: it's shown once a second, the
        // rest at once.
        let throttle = NetworkThrottle(1, owner: window)
        var shownBase = ""
        window.track { [self] in
            let name = session.project.name
            self.window.title = name
            self.windowTitle.title = name
            let (base, speed) = self.subtitle
            if base != shownBase {
                shownBase = base
                self.windowTitle.subtitle = base + speed
            } else {
                // (What it says when it's shown.)
                throttle.run {
                    let (base, speed) = self.subtitle
                    self.windowTitle.subtitle = base + speed
                }
            }
        }
        window.track { [self] in
            guard let error = session.saveError else {
                self.lastSaveError = nil
                return
            }
            guard error != self.lastSaveError else { return }
            self.lastSaveError = error
            AlertDialog("Can’t save the network", body: error)
                .response("ok", "_OK", .suggested)
                .defaults(default: "ok", close: "ok")
                .present(over: self.window)
        }
        let center = NotificationCenter.default
        let share = center.addObserver(forName: NetworkStudioCommands.shareRequest, object: nil, queue: .main) { [weak self] note in
            let url = note.object as? URL
            MainActor.assumeIsolated {
                guard let self, let url, NetworkSession.existing(url) === self.session else { return }
                self.window.present()
                InternetShareDialog.present(session: self.session, over: self.window)
            }
        }
        window.onDestroy { center.removeObserver(share) }
    }

    /// The subtitle: what changes now and then, and the speed.
    private var subtitle: (String, String) {
        let on = session.controllers.count
        let machines = session.project.nodes.filter(\.isMachine).count
        var text = "\(on) of \(machines) on"
        if let link = session.project.internetRoom {
            let state = session.room?.state
            let ended = state.map { if case .ended = $0 { true } else { false } } ?? false
            text += state == .connected ? " · On the Internet (\(link.roomName))"
                : ended ? " · Internet room ended"
                : " · Connecting to \(link.roomName)…"
        }
        var speed = ""
        if session.paused {
            text += " · Paused"
        } else if !session.status.stoppedStations.isEmpty && session.runtime.network.pausesOnBreakpoint {
            text += " · Paused for the debugger"
        } else if on > 0 && session.status.speed > 0 {
            speed = String(format: " · %.0f%% speed", min(session.status.speed, 9.99) * 100)
            if session.status.threads > 1 {
                speed += " · \(session.status.threads) cores"
            }
        }
        return (text, speed)
    }

    // MARK: Actions

    private func buildActions() {
        let session = session
        window.action("power-on-all") { session.powerOnAll() }
        let powerOff = window.action("power-off-all") { [self] in self.confirmPowerOff() }
        let breakAll = window.action("break-all") { [self] in self.confirmBreak() }
        window.action("pause-network") { session.setPaused(!session.paused) }
        window.action("share") { [self] in InternetShareDialog.present(session: session, over: self.window) }
        window.action("save-as") { NetworkStudioCommands.saveAs(session) }
        window.action("reveal") { Platform.reveal(session.url) }
        window.action("previous-machine") { [self] in self.step(false) }
        window.action("next-machine") { [self] in self.step(true) }
        window.action("toggle-inspector") { [self] in self.split.showsSidebar.toggle() }
        let print = window.action("print-centre") { PrintCentreWindow.show() }
        for (index, mode) in Mode.allCases.enumerated() {
            window.action("show-\(mode.rawValue)") { [self] in self.show(mode) }
            window.shortcut("<Alt>\(index + 1)", action: "win.show-\(mode.rawValue)")
        }
        // Open Recent Network, by path.
        let recent = g_simple_action_new("open-recent-network", macbeeb_variant_type_string())!
        GObjectRef(recent).onPointer("activate") { parameter in
            guard let parameter else { return }
            NetworkStudioCommands.open(URL(fileURLWithPath: String(cString: g_variant_get_string(OpaquePointer(parameter), nil))))
        }
        g_action_map_add_action(OpaquePointer(window.widget), recent)
        g_object_unref(gpointer(recent))
        window.track {
            let on = !session.controllers.isEmpty
            powerOff.isEnabled = on
            breakAll.isEnabled = on
            print.isEnabled = session.project.nodes.contains { $0.kind == .printServer }
        }
        window.shortcut("<Alt>bracketleft", action: "win.previous-machine")
        window.shortcut("<Alt>bracketright", action: "win.next-machine")
        window.shortcut("F9", action: "win.toggle-inspector")
        window.shortcut("<Control><Shift>s", action: "win.save-as")
        window.shortcut("<Alt><Shift>s", action: "win.save-as")
    }

    /// The next (or previous) machine gets the keyboard, in the tiles; in
    /// focus, it's shown large too.
    private func step(_ forward: Bool) {
        session.focusNext(forward)
        if stack.visible == Mode.focus.rawValue, let id = session.focused {
            session.update { $0.workspace.focus = id }
            session.selection = [id]
        }
    }

    private func confirmBreak() {
        let session = session
        AlertDialog("Reset every machine?",
                    body: "Each machine gets a Break, as if its Break key were pressed. Programs that are running stop.")
            .response("cancel", "_Cancel")
            .response("break", "_Break All", .suggested)
            .defaults(default: "break", close: "cancel")
            .choose(over: window) { if $0 == "break" { session.resetAll() } }
    }

    private func confirmPowerOff() {
        let session = session
        AlertDialog("Switch every machine off?", body: "What’s in their memory is lost. Their discs are kept.")
            .response("cancel", "_Cancel")
            .response("off", "_Power Off All", .destructive)
            .defaults(default: "cancel", close: "cancel")
            .choose(over: window) { if $0 == "off" { session.powerOffAll() } }
    }

    // MARK: The header bar

    private func buildHeader(_ header: HeaderBar) {
        let session = session
        // Start: the views.
        let switcher = adw_inline_view_switcher_new()!
        adw_inline_view_switcher_set_stack(OpaquePointer(switcher), stack.opaque)
        adw_inline_view_switcher_set_display_mode(OpaquePointer(switcher), ADW_INLINE_VIEW_SWITCHER_LABELS)
        let views = Widget(cast(switcher) as WidgetPointer)
        views.tooltip("Arrange the network, or use its machines side by side").align(vertical: GTK_ALIGN_CENTER)
        header.start(views)

        // End (packed from the right): the menu, the inspector, sharing,
        // printing, then the network's power.
        let menu = Menu {}
        var menuInputs: (inRoom: Bool, recent: [URL])?
        let menuButton = MenuButton(icon: "open-menu-symbolic", menu: menu).primary().tooltip("Main Menu")
        let split = split
        let inspector = ToggleButton(icon: "sidebar-show-right-symbolic", isOn: true) { on in split.showsSidebar = on }
        split.onShowSidebarChanged { [inspector] shown in
            inspector.isOn = shown
            inspector.tooltip(shown ? "Hide the inspector (F9)" : "Show the inspector (F9)")
        }
        inspector.tooltip("Hide the inspector (F9)").accessibleLabel("Inspector")
        let share = Button(icon: "web-browser-symbolic").action("win.share")
        let print = Button(icon: "printer-symbolic").action("win.print-centre")
            .tooltip("What the printer server has printed, on paper (Print Centre)")
        let pause = Button(icon: "media-playback-pause-symbolic").action("win.pause-network")
        let breakAll = Button(icon: "object-rotate-left-symbolic").action("win.break-all")
            .tooltip("Press Break on every machine").accessibleLabel("Break All")
        let powerOff = Button(icon: "media-playback-stop-symbolic").action("win.power-off-all")
            .tooltip("Switch off every machine").accessibleLabel("Power Off All")
        let powerOn = Button(icon: "system-shutdown-symbolic").action("win.power-on-all")
            .tooltip("Switch on every machine").accessibleLabel("Power On All")
        let power = Box(.horizontal, spacing: 0) { powerOn; powerOff; breakAll }
        power.linked()
        header.end(menuButton).end(inspector).end(share).end(print).end(pause).end(power)

        window.track { [menu] in
            let inRoom = session.isInRoom
            share.tooltip(inRoom ? "This network's Internet room: invitations, who's in it, and leaving"
                          : "Share this network over the Internet, with a link or a code")
            share.accessibleLabel(inRoom ? "Internet Network" : "Share Over Internet")
            share.setStyle("accent", inRoom)
            print.isVisible = session.project.nodes.contains { $0.kind == .printServer }
            let paused = session.paused
            let icon = paused ? "media-playback-start-symbolic" : "media-playback-pause-symbolic"
            if pause.iconName != icon { pause.iconName = icon }
            pause.tooltip(paused ? "Carry on: every machine starts again together" : "Stop time on the whole network: nothing times out")
            pause.accessibleLabel(paused ? "Resume Network" : "Pause Network")
            let recent = RecentNetworks.shared.existing
            if menuInputs?.inRoom != inRoom || menuInputs?.recent != recent {
                menuInputs = (inRoom, recent)
                menu.set(Self.mainMenu(inRoom: inRoom, recent: recent))
            }
        }

        // Narrow windows keep the essentials (the rest are in the menu), and
        // the inspector floats over the network.
        let medium = macbeeb_breakpoint("max-width: 1000sp")!
        macbeeb_network_breakpoint_set_enum(medium, gpointer(switcher), "display-mode",
                                            Int32(ADW_INLINE_VIEW_SWITCHER_ICONS.rawValue))
        adw_application_window_add_breakpoint(cast(window.widget), medium)
        let narrow = macbeeb_breakpoint("max-width: 860sp")!
        macbeeb_network_breakpoint_set_enum(narrow, gpointer(switcher), "display-mode",
                                            Int32(ADW_INLINE_VIEW_SWITCHER_ICONS.rawValue))
        macbeeb_network_breakpoint_set_bool(narrow, gpointer(split.widget), "collapsed", 1)
        macbeeb_network_breakpoint_set_bool(narrow, gpointer(split.widget), "show-sidebar", 0)
        macbeeb_breakpoint_hide(narrow, breakAll.widget)
        macbeeb_breakpoint_hide(narrow, powerOff.widget)
        macbeeb_breakpoint_hide(narrow, print.widget)
        adw_application_window_add_breakpoint(cast(window.widget), narrow)
    }

    /// The primary menu: the Mac's File menu for networks, and the app's.
    static func mainMenu(inRoom: Bool, recent: [URL]) -> [MenuEntry] {
        [
            MenuSection {
                MenuItem("New Network…", "app.new-network")
                MenuItem("Open Network…", "app.open-network")
                if !recent.isEmpty {
                    Submenu("Open Recent Network") {
                        for url in recent {
                            MenuItem(url.deletingPathExtension().lastPathComponent, "win.open-recent-network", target: url.path)
                        }
                    }
                }
                MenuItem("Join a Network…", "app.join-network")
            },
            MenuSection {
                MenuItem("Save Network As…", "win.save-as", accel: "<Control><Shift>s")
                MenuItem(inRoom ? "Internet Network…" : "Share Network Over Internet…", "win.share")
                MenuItem("Show in Files", "win.reveal")
            },
            MenuSection {
                MenuItem("Power On All", "win.power-on-all")
                MenuItem("Power Off All…", "win.power-off-all")
                MenuItem("Break All…", "win.break-all")
                MenuItem("Pause or Resume Network", "win.pause-network")
            },
            MenuSection {
                MenuItem("Show or Hide Inspector", "win.toggle-inspector", accel: "F9")
                MenuItem("Print Centre", "app.print-centre")
                MenuItem("New BBC Micro Window", "app.new-window", accel: "<Alt><Control>n")
            },
            MenuSection {
                MenuItem("Preferences", "app.preferences", accel: "<Control>comma")
                MenuItem("Keyboard Shortcuts", "app.shortcuts", accel: "<Control>question")
                MenuItem("About MacBeeb", "app.about")
            },
        ]
    }

    // MARK: Closing

    private func handleClosing() {
        let session = session
        window.onCloseRequest { [self] in
            // A new network: keep it, or delete it?
            guard !self.mayClose, session.project.isDraft else { return false }
            if !self.askingToKeep {
                self.askingToKeep = true
                KeepNetworkDialog.present(session: session, over: self.window) { [self] close in
                    self.askingToKeep = false
                    if close {
                        self.mayClose = true
                        self.window.close()
                    }
                }
            }
            return true
        }
        window.onDestroy { [self] in
            Self.open[ObjectIdentifier(session)] = nil
            self.canvas = nil
            session.close()
        }
    }
}
