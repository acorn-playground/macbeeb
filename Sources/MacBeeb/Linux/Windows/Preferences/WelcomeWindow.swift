import BeebCore
import BeebLibrary
import BeebNetwork
import CGtk
import Foundation
import Observation

/// The first thing MacBeeb shows (unless Preferences says otherwise): its
/// three parts, a BBC Micro, the Game Library and the Network Studio, and
/// things worth trying, so there's a way into all of it. (The Mac's
/// WelcomeView.)
@MainActor
enum WelcomeWindow {
    static let key = "welcome"
    static let title = "Welcome to MacBeeb"

    /// Whether the launch has been dealt with (the Network Studio setting
    /// passes straight through).
    private static var launched = false
    /// What's New has notes the user hasn't seen (until they look).
    static var unseenNotes = false

    static func show() {
        if !launched {
            launched = true
            if LaunchScreen.atLaunch == .network {
                NetworkStudioCommands.showStudio()
                return
            }
            // Its tile says so, rather than opening the notes.
            unseenNotes = WhatsNew.shouldShowOnLaunch()
            if LaunchScreen.isSelfTest { addSamples() }
        }
        Windows.show(key) {
            let window = WelcomeScreen().window
            widget = gpointer(window.widget)
            // `-MacBeebSelfTestWelcomeClose YES`: closed again (trying
            // WelcomeReturn: closing it quits).
            if LaunchScreen.isSelfTest, UserDefaults.standard.bool(forKey: "MacBeebSelfTestWelcomeClose") {
                MainLoop.after(1) { window.close() }
            }
            return window
        }
    }

    /// `-MacBeebSelfTestWelcomeSample YES`, with `-MacBeebMachinesFile` in
    /// the temporary folder: a window capture's saved machines, and the
    /// What's New tile's badge.
    private static func addSamples() {
        guard UserDefaults.standard.bool(forKey: "MacBeebSelfTestWelcomeSample"),
              MachineConfigurations.defaultURL.path.hasPrefix("/tmp/") else { return }
        if MachineConfigurations.shared.machines.isEmpty {
            _ = try? MachineConfigurations.shared.save(MachineSetup(model: .master128), as: "Master for Elite")
            _ = try? MachineConfigurations.shared.save(MachineSetup(model: .modelB, secondProcessor: true), as: "Tube Model B")
        }
        unseenNotes = true
    }

    /// The welcome window, if it's open.
    static var window: Window? { Windows.existing(key) }

    /// The welcome window's widget, last it was open (to know it as it
    /// goes).
    private(set) static var widget: gpointer?
}

/// The welcome window's content.
@MainActor
final class WelcomeScreen {
    let window: Window
    private let notesBadge = Label("New", style: "macbeeb-welcome-badge")
    /// Switch On: the focus to begin with.
    private var primary: Widget?
    /// The tiles' two halves, side by side or one above the other.
    private var tilePairs: [Box] = []
    private let footerBox = Box(.horizontal, spacing: 10)
    private var footerHint: Label?

    init() {
        PreferencesStyles.install()
        window = Window(title: WelcomeWindow.title, width: 1100, height: 940)
        window.minimumSize(width: 360, height: 400)

        let cards = Box(.horizontal, spacing: 18).homogeneous()
        cards.append(machineCard())
        cards.append(gamesCard())
        cards.append(networkCard())
        let boot = BootScreenArt.make()
        let tiles = exploreTiles()
        let footer = footer()
        let content = Box(.vertical, spacing: 24) {
            hero(boot)
            cards
            explore(tiles)
            footer
        }
        .margin(top: 6, bottom: 20, start: 36, end: 36)
        let column = Clamp(content, maximum: 1180)
        let page = ScrolledWindow(column, horizontal: GTK_POLICY_NEVER)
        if LaunchScreen.isSelfTest, UserDefaults.standard.bool(forKey: "MacBeebSelfTestWelcomeScroll") {
            MainLoop.after(1) { page.scrollToEnd() }
        }
        let menu = MenuButton(icon: "open-menu-symbolic", menu: Menu {
            MenuSection {
                MenuItem("New BBC Micro Window", "app.new-window")
                MenuItem("Game Library", "app.library")
            }
            MenuSection {
                MenuItem("Preferences", "app.preferences")
                MenuItem("Keyboard Shortcuts", "app.shortcuts")
                MenuItem("What’s New", "app.whats-new")
                MenuItem("About MacBeeb", "app.about")
            }
        })
        .tooltip("Main Menu")
        .primary()
        let header = HeaderBar(title: Box(.horizontal)).end(menu)
        let toolbar = ToolbarView(content: page).top(header).style("macbeeb-welcome")
        window.content = toolbar
        App.addStandardShortcuts(to: window)

        // Narrower windows: one column, the three parts one above another
        // (and no boot screen), then narrower margins. (The narrowest
        // breakpoint that matches applies alone, so it has the wider one's
        // setters.)
        let vertical = gint(GTK_ORIENTATION_VERTICAL.rawValue)
        func oneColumn(_ breakpoint: OpaquePointer) {
            macbeeb_preferences_breakpoint_set_enum(breakpoint, gpointer(cards.widget), "orientation", vertical)
            macbeeb_preferences_breakpoint_set_bool(breakpoint, gpointer(cards.widget), "homogeneous", 0)
            macbeeb_preferences_breakpoint_set_enum(breakpoint, gpointer(tiles.widget), "orientation", vertical)
            macbeeb_preferences_breakpoint_set_int(breakpoint, gpointer(column.widget), "maximum-size", 640)
            macbeeb_breakpoint_hide(breakpoint, boot.widget)
        }
        PreferencesUI.addBreakpoint(to: window, "max-width: 980sp") { breakpoint in
            oneColumn(breakpoint)
        }
        PreferencesUI.addBreakpoint(to: window, "max-width: 560sp") { breakpoint in
            oneColumn(breakpoint)
            for half in tilePairs {
                macbeeb_preferences_breakpoint_set_enum(breakpoint, gpointer(half.widget), "orientation", vertical)
            }
            macbeeb_preferences_breakpoint_set_enum(breakpoint, gpointer(footer.widget), "orientation", vertical)
            if let hint = footerHint {
                macbeeb_preferences_breakpoint_set_float(breakpoint, gpointer(hint.widget), "xalign", 0)
            }
            macbeeb_preferences_breakpoint_set_int(breakpoint, gpointer(content.widget), "margin-start", 16)
            macbeeb_preferences_breakpoint_set_int(breakpoint, gpointer(content.widget), "margin-end", 16)
        }
        // (Window captures, at other sizes.)
        let width = UserDefaults.standard.integer(forKey: "MacBeebSelfTestWelcomeWidth")
        if LaunchScreen.isSelfTest, width > 0 {
            window.setDefaultSize(width: Int32(width), height: 940)
        }
        if let primary {
            gtk_window_set_focus(window.window, primary.widget)
        }

        addActions()
        window.keep(self)
    }

    /// Opens a window and puts this one away.
    private func go(_ action: () -> Void) {
        action()
        window.close()
    }

    /// The menus' commands: a saved machine, a recent network.
    private func addActions() {
        PreferencesUI.addStringAction(to: window, "start-machine") { [self] id in
            guard let id = UUID(uuidString: id), let saved = MachineConfigurations.shared[id] else { return }
            go { MachineWindow.openNew().machine.use(saved.setup) }
        }
        PreferencesUI.addStringAction(to: window, "open-network") { [self] path in
            go { NetworkStudioWindow.show(URL(fileURLWithPath: path)) }
        }
    }

    // MARK: Hero

    private func hero(_ boot: Widget) -> Widget {
        let welcome = Label("Welcome to", style: "title-2", "dim-label")
        let name = Label("MacBeeb", style: "macbeeb-welcome-title")
        let blurb = Label("The BBC Micro, on your \(Platform.keyboardName). Switch one on and type, play the classics, or wire up a classroom of them on Econet and watch them work together.",
                          style: "macbeeb-welcome-blurb", "dim-label")
            .wrap()
            .maxWidthChars(48)
        let words = Box(.vertical, spacing: 12) {
            welcome
            name
            blurb
            TeletextStripeArt.make().margin(top: 4)
        }
        .align(vertical: GTK_ALIGN_CENTER)
        .expand(horizontal: true)
        return Box(.horizontal, spacing: 32) {
            words
            boot.align(vertical: GTK_ALIGN_CENTER)
        }
    }

    // MARK: The three parts

    private func card(_ kind: String, icon: String, title: String, blurb: String, art: Widget,
                      @WidgetList actions: () -> [Widget]) -> Widget {
        art.style("macbeeb-welcome-art", kind).size(height: 124)
        gtk_widget_set_overflow(art.widget, GTK_OVERFLOW_HIDDEN)
        let heading = Box(.horizontal, spacing: 8) {
            Icon(icon, size: 20).style("macbeeb-welcome-icon")
            Label(title, style: "title-2")
        }
        let buttons = Box(.vertical, spacing: 8, actions)
        return Box(.vertical, spacing: 12) {
            art
            heading
            Label(blurb, style: "dim-label").wrap()
            Spacer()
            buttons
        }
        .style("macbeeb-welcome-card", kind)
    }

    private func machineCard() -> Widget {
        let menu = Menu {}
        let mine = MenuButton(label: "Start One of Your Machines", menu: menu)
            .style("pill")
            .tooltip("A machine configuration you’ve saved")
        // (As machines are saved, or removed.)
        mine.track {
            let saved = MachineConfigurations.shared.machines
            mine.isVisible = !saved.isEmpty
            menu.set(saved.map { MenuItem($0.name, "win.start-machine", target: $0.id.uuidString) })
        }
        return card("machine", icon: "computer-symbolic", title: "BBC Micro",
                    blurb: "A Model B, B+, Master 128 or Compact. Add a second processor, plug ROMs and cartridges into its sockets, and step through its 6502 in the debugger.",
                    art: ModelChipsArt.make()) {
            mine
            remember(Button("Switch On", icon: "system-shutdown-symbolic") { [self] in go { MachineWindow.openNew() } }
                .style("suggested-action", "pill")
                .tooltip("Open a BBC Micro, set up as the last one was"))
        }
    }

    private func remember(_ button: Widget) -> Widget {
        primary = button
        return button
    }

    private func gamesCard() -> Widget {
        card("games", icon: "applications-games-symbolic", title: "Game Library",
             blurb: "Elite, Repton, Chuckie Egg, Exile and more, with their box art, set up and ready to play. Add your own discs, and keep your saves.",
             art: CoverFanArt.make()) {
            Button("Browse Games", icon: "input-gaming-symbolic") { [self] in go { BookshelfWindow.show() } }
                .style("suggested-action", "pill")
        }
    }

    private func networkCard() -> Widget {
        let menu = Menu {}
        let recent = MenuButton(label: "Open Recent", menu: menu).style("pill")
        recent.track {
            let urls = RecentNetworks.shared.existing
            recent.isVisible = !urls.isEmpty
            menu.set(urls.prefix(8).map { url in
                MenuItem(url.deletingPathExtension().lastPathComponent, "win.open-network", target: url.path)
            })
        }
        return card("network", icon: "network-workgroup-symbolic", title: "Network Studio",
                    blurb: "A classroom of BBC Micros on Econet, each one running for real: file servers, printers, and messages and programs passed between them.",
                    art: EconetArt.make()) {
            Button("Join with a Code…", icon: "web-browser-symbolic") { [self] in go { JoinRoomWindow.show() } }
                .style("pill")
                .tooltip("Join someone’s network over the Internet, with the code or link they gave you")
            recent
            Button("New Network", icon: "list-add-symbolic") { [self] in go { NetworkStartWindow.show() } }
                .style("suggested-action", "pill")
        }
    }

    // MARK: Explore

    private func exploreTiles() -> Box {
        let version = WhatsNew.releases.first?.version ?? WhatsNew.currentVersion
        notesBadge.isVisible = WelcomeWindow.unseenNotes
        let notesBadge = notesBadge
        let left = Box(.horizontal, spacing: 12) {
            tile("purple", icon: "starred-symbolic", title: "Eight-BBC Mandelbrot", detail: "In colour, over Econet") { [self] in
                mandelbrot()
            }
            tile("green", icon: "media-flash-symbolic", title: "Plug in ROMs", detail: "Sockets and cartridges") { [self] in
                go { GuideWindow.show(page: "rom-sockets") }
            }
        }
        .homogeneous()
        let right = Box(.horizontal, spacing: 12) {
            tile("pink", icon: "utilities-terminal-symbolic", title: "Let an AI drive", detail: "Connect an agent with MCP") { [self] in
                go { AgentWindows.showConnect() }
            }
            tile("blue", icon: "software-update-available-symbolic", title: "What’s new in \(version)",
                 detail: "Everything in this version", badge: notesBadge) {
                WelcomeWindow.unseenNotes = false
                notesBadge.isVisible = false
                WhatsNewWindow.show()
            }
        }
        .homogeneous()
        tilePairs = [left, right]
        return Box(.horizontal, spacing: 12) {
            left
            right
        }
        .homogeneous()
    }

    private func explore(_ tiles: Widget) -> Widget {
        Box(.vertical, spacing: 10) {
            Label("Things to Try", style: "heading", "dim-label")
            tiles
        }
    }

    /// A smaller suggestion.
    private func tile(_ colour: String, icon: String, title: String, detail: String, badge: Label? = nil,
                      _ action: @escaping @MainActor () -> Void) -> Widget {
        let heading = Box(.horizontal, spacing: 6) {
            Label(title, style: "macbeeb-welcome-tile-title").ellipsize()
        }
        if let badge {
            heading.append(badge.align(vertical: GTK_ALIGN_CENTER))
        }
        let words = Box(.vertical, spacing: 2) {
            heading
            Label(detail, style: "caption", "dim-label").ellipsize()
        }
        .align(vertical: GTK_ALIGN_CENTER)
        .expand(horizontal: true)
        let content = Box(.horizontal, spacing: 12) {
            Icon(icon, size: 24).style("macbeeb-welcome-icon").size(width: 30)
            words
        }
        // (Its name, for screen readers, is what it says, badge and all.)
        return Button(child: content, action)
            .style("card", "macbeeb-welcome-tile", colour)
    }

    private func mandelbrot() {
        do {
            // A draft, as the Network Studio's templates make them: closing
            // it asks whether to keep it.
            let template = NetworkTemplate.mandelbrotInColour
            let url = RecentNetworks.newURL(named: template.title)
            var project = try NetworkPackage.create(template, at: url)
            project.draft = true
            try NetworkPackage.save(project, to: url)
            go { NetworkStudioWindow.show(url) }
        } catch {
            AlertDialog("Can’t make the network", body: error.localizedDescription)
                .response("ok", "_OK", .suggested)
                .defaults(default: "ok", close: "ok")
                .present(over: window)
        }
    }

    // MARK: Footer

    private func footer() -> Widget {
        let setting = PreferencesUI.LaunchSetting.shared
        let screens = LaunchScreen.allCases
        let picker = DropDown(screens.map(\.title), selected: screens.firstIndex(of: setting.value) ?? 0) { index in
            if screens.indices.contains(index) { setting.value = screens[index] }
        }
        picker.accessibleLabel("When MacBeeb opens, show")
        picker.align(vertical: GTK_ALIGN_CENTER)
        picker.track { picker.selected = screens.firstIndex(of: setting.value) ?? 0 }
        let hint = Label("Main Menu ▸ Welcome to MacBeeb brings this back.", style: "caption", "dim-label")
            .wrap()
            .expand(horizontal: true)
        gtk_label_set_xalign(cast(hint.widget), 1)
        let choice = Box(.horizontal, spacing: 10) {
            Label("When MacBeeb opens, show", style: "dim-label")
            picker
        }
        footerBox.append(choice)
        footerBox.append(hint)
        footerHint = hint
        return footerBox
    }
}
