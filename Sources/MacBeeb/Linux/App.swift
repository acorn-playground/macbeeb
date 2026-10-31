import BeebCore
import BeebLibrary
import BeebNetwork
import CGtk
import Foundation

/// MacBeeb on Linux: a GNOME application (GTK 4 and libadwaita), one
/// instance at a time (files opened again go to it). The Mac's is
/// MacBeebApp and its AppDelegate.
@MainActor
enum App {
    static let id = "com.accidentalfish.MacBeeb"

    static func main() -> Int32 {
        // Arguments for the app itself (-MacBeebSelfTest path, as on the
        // Mac, which UserDefaults reads) aren't GTK's.
        var arguments = CommandLine.arguments
        var index = 1
        while index < arguments.count {
            if arguments[index].hasPrefix("-MacBeeb") {
                arguments.removeSubrange(index..<min(index + 2, arguments.count))
            } else {
                index += 1
            }
        }
        MainLoop.install()
        let app = Application(id: id)
        handleOptions(app)
        app.onStartup(startup)
        app.onActivate(activate)
        app.onOpen(open)
        return app.run(arguments)
    }

    private static var started = false
    /// An app action asked for on the command line, to run in place of
    /// the usual first window.
    private static var launchAction: String?

    /// `--new-window` and `--library` (the desktop file's actions): run in
    /// the instance that's running, if there is one, else at launch.
    private static func handleOptions(_ app: Application) {
        let options = [("new-window", "Open a new BBC Micro window"), ("library", "Show the game library")]
        for (name, description) in options {
            g_application_add_main_option(cast(app.app), name, 0, GOptionFlags(rawValue: 0), G_OPTION_ARG_NONE,
                                          description, nil)
        }
        typealias Handler = @MainActor (UnsafeMutablePointer<GVariantDict>?) -> Int32
        let handler: Handler = { dictionary in
            guard let dictionary,
                  let name = options.map(\.0).first(where: { g_variant_dict_contains(dictionary, $0) != 0 }) else { return -1 }
            let application: UnsafeMutablePointer<GApplication> = cast(Application.shared.app)
            guard g_application_register(application, nil, nil) != 0 else { return 1 }
            if g_application_get_is_remote(application) != 0 {
                g_action_group_activate_action(OpaquePointer(application), name, nil)
                return 0
            }
            launchAction = name
            return -1
        }
        macbeeb_signal_connect(gpointer(app.app), "handle-local-options", unsafeBitCast(
            { (_: gpointer?, dictionary: UnsafeMutablePointer<GVariantDict>?, data: gpointer?) -> gint in
                nonisolated(unsafe) let dictionary = dictionary, data = data
                return MainActor.assumeIsolated { Boxed<Handler>.from(data)(dictionary) }
            } as @convention(c) (gpointer?, UnsafeMutablePointer<GVariantDict>?, gpointer?) -> gint, to: GCallback.self),
            Boxed<Handler>(handler).retained, { data, _ in AnyBox.release(data) }, 0)
    }

    private static func startup() {
        Application.shared.followSystemAppearance()
        installStyles()
        Icons.install()
        installActions()
        // Picks up downloads awaited before the app last quit.
        _ = ClassicsLibrary.shared
        // Downloads bring the library forward, and covers decode with GDK.
        BookshelfWindow.startWatching()
        // Agents' requests to open a network open its studio.
        NetworkStudioCommands.installObservers()
        _ = Joysticks.shared
        // The Print Centre comes forward when a job arrives.
        PrintCentreWindow.watchArrivals()
        if !NetworkSelfTest.runMCPIfRequested() {
            NetworkSelfTest.runIfRequested()
        }
        WelcomeReturn.start()
    }

    /// Launched (or launched again with nothing to open): what Settings >
    /// General > When MacBeeb opens says, the first time; after that, the
    /// window in front, or a machine.
    private static func activate() {
        defer { started = true }
        if !started, let action = launchAction {
            g_action_group_activate_action(OpaquePointer(Application.shared.app), action, nil)
            return
        }
        if started {
            if let window = Application.shared.windows.first {
                gtk_window_present(window)
            } else {
                MachineWindow.openNew()
            }
            return
        }
        switch LaunchScreen.atLaunch {
        case .machine:
            MachineWindow.openNew()
        case .games:
            BookshelfWindow.show()
        case .welcome, .network:
            WelcomeWindow.show()
        }
        if WhatsNew.shouldShowOnLaunch() && !LaunchScreen.isSelfTest {
            WhatsNewWindow.show()
        }
    }

    /// Files opened with MacBeeb (from the file manager, the command line,
    /// or an invitation link): into the machine in front, or a new one.
    private static func open(_ urls: [URL]) {
        started = true
        for url in urls {
            if JoinRequests.isJoinLink(url) {
                JoinRequests.shared.handle(url)
                JoinRoomWindow.show()
                continue
            }
            if url.pathExtension.lowercased() == NetworkPackage.fileExtension {
                NetworkStudioWindow.show(url)
                continue
            }
            let window = MachineController.frontmost.flatMap(MachineWindow.existing(for:)) ?? MachineWindow.openNew()
            window.open(url)
        }
    }

    /// A window became active: the app is (as the Mac's becomes active).
    static func noteActive() {
        let now = Date()
        // (Once per activation: windows taking turns don't count.)
        guard now.timeIntervalSince(lastActive) > 1 else {
            lastActive = now
            return
        }
        lastActive = now
        NotificationCenter.default.post(name: Platform.didBecomeActive, object: nil)
    }

    private static var lastActive = Date.distantPast

    // MARK: Actions

    private static func installActions() {
        let app = Application.shared!
        app.action("new-window") { MachineWindow.openNew() }
        app.action("library") { BookshelfWindow.show() }
        app.action("welcome") { WelcomeWindow.show() }
        app.action("preferences") { PreferencesWindow.show() }
        app.action("shortcuts") { ShortcutsDialog.show() }
        app.action("about") { AboutDialog.show() }
        app.action("check-updates") { Updates.check() }
        app.action("whats-new") { WhatsNewWindow.show() }
        app.action("credits") { CreditsWindow.show() }
        let guide = Action(choice: "guide", value: "") { page in GuideWindow.show(page: page) }
        g_action_map_add_action(OpaquePointer(app.app), guide.gAction)
        app.action("vscode-extension") { Platform.open(VSCodeExtension.marketplace) }
        app.action("rom-library") { ROMLibraryWindow.show() }
        app.action("machine-configurations") { MachineConfigurationsWindow.show() }
        app.action("new-network") { NetworkStartWindow.show() }
        app.action("open-network") { NetworkStudioCommands.chooseAndOpen() }
        app.action("join-network") { JoinRoomWindow.show() }
        app.action("add-remote-elite") { JoinRoomWindow.showForElite() }
        app.action("network-studio") { NetworkStudioCommands.showStudio() }
        app.action("print-centre") { PrintCentreWindow.show() }
        app.action("connect-agent") { AgentWindows.showConnect() }
        app.action("agent-log") { AgentWindows.showLog() }
        app.action("quit") { app.quit() }
        // (Shortcuts are each window's own: see `appShortcuts`.)
    }

    /// The app's own shortcuts, in every window, with Alt as in machine
    /// windows (Control is the BBC's there; other windows also take GNOME's
    /// usual Control ones). Each window has them as its own shortcuts, not
    /// GTK's application accelerators, which would see a key before the
    /// BBC's screen could take it.
    static let appShortcuts: [(action: String, accels: [String])] = [
        ("app.new-window", ["<Alt><Control>n"]),
        ("app.library", ["<Alt><Shift>k"]),
        ("app.welcome", ["<Alt><Shift>1", "<Alt>exclam"]),
        ("app.new-network", ["<Alt><Shift>n"]),
        ("app.join-network", ["<Alt><Shift>j"]),
        ("app.network-studio", ["<Alt><Control>0"]),
        ("app.print-centre", ["<Alt><Control>p"]),
        ("app.preferences", ["<Alt>comma"]),
        ("app.shortcuts", ["<Alt>question", "<Alt><Shift>slash"]),
        ("app.quit", ["<Alt>q"]),
        ("app.agent-log", ["<Alt><Control>l"]),
    ]

    /// GNOME's usual Control shortcuts, for a window that isn't a machine's
    /// (where Control is the BBC's).
    static func addStandardShortcuts(to window: Window) {
        window.shortcuts(appShortcuts + [
            ("app.quit", ["<Control>q"]),
            ("window.close", ["<Control>w", "<Alt>w"]),
            ("app.preferences", ["<Control>comma"]),
            ("app.shortcuts", ["<Control>question"]),
        ])
    }

    // MARK: Styles

    private static func installStyles() {
        let css = """
        .machine-screen { background: black; }
        picture.pixelated { -gtk-icon-filter: none; }
        .osd.monospace { padding: 4px 8px; border-radius: 6px; }
        .cover { border-radius: 8px; }
        .tile { border-radius: 12px; }
        .light-label { font-size: 7pt; font-weight: 600; }
        """
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider),
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }
}

/// The app's own icons (the BBC's things GNOME's theme hasn't got), from
/// its installed share folder or the source tree.
@MainActor
enum Icons {
    static func install() {
        let theme = gtk_icon_theme_get_for_display(gdk_display_get_default())
        for folder in AppResources.iconFolders {
            gtk_icon_theme_add_search_path(theme, folder.path)
        }
    }
}

/// Where the Linux app finds its files: installed beside it
/// (share/macbeeb), or, run from the source tree, in the repository.
enum AppResources {
    /// The repository, when run from the source tree.
    static let sourceRoot: URL? = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) ? root : nil
    }()

    /// The installed share folder: beside the executable (lib/macbeeb/share,
    /// as scripts/install-linux.sh lays it out), or ../share/macbeeb.
    static let installed: URL? = {
        let executable = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
        let folder = executable.deletingLastPathComponent()
        return [folder.appendingPathComponent("share"),
                folder.deletingLastPathComponent().appendingPathComponent("share/macbeeb")]
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("version").path) }
    }()

    /// A file shipped with the app: its installed copy, or the source
    /// tree's (`sourcePath`, relative to the repository).
    static func file(installed name: String, source sourcePath: String) -> URL? {
        if let installed {
            let url = installed.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let sourceRoot {
            let url = sourceRoot.appendingPathComponent(sourcePath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static var iconFolders: [URL] {
        [file(installed: "icons", source: "Resources/Linux/icons")].compactMap { $0 }
    }
}

/// The app's shortcuts as the Mac's are written: its Command is Alt here
/// (the BBC has neither, and Control is the BBC's), Shift-Command is
/// Shift+Alt, and where Alt alone is taken, Option-Command is Ctrl+Alt.
enum Shortcuts {
    /// The Mac's shortcuts that the guides quote, as Linux's.
    static let fromMac: [String: String] = [
        "⌘B": "Alt+B", "⌘V": "Alt+V", "⌘O": "Alt+O", "⌘N": "Alt+N", "⌘S": "Alt+S", "⌘P": "Alt+P",
        "⌘0": "Alt+0", "⇧⌘R": "Shift+Alt+R", "⇧⌘B": "Shift+Alt+B", "⇧⌘S": "Shift+Alt+S",
        "⇧⌘L": "Shift+Alt+L", "⇧⌘I": "Shift+Alt+I", "⇧⌘K": "Shift+Alt+K", "⇧⌘N": "Shift+Alt+N",
        "⇧⌘J": "Shift+Alt+J", "⌃⌘B": "Ctrl+Alt+B", "⌃⌘M": "Alt+M", "⌃⌘Y": "Alt+Y", "⌥⌘E": "Alt+E",
        "⌥⌘F": "Alt+F", "⌥⌘D": "Alt+D", "⌥⌘R": "Alt+R", "⌥⌘T": "Alt+T", "⌥⌘O": "Shift+Alt+O",
        "⌥⌘N": "Ctrl+Alt+N", "⌥⌘P": "Ctrl+Alt+P", "⌥⌘0": "Ctrl+Alt+0", "⌥⌘L": "Ctrl+Alt+L",
        "⌥⌘←": "Alt+←", "⇧⌥⌘←": "Shift+Alt+←", "⇧⌘F6": "Shift+Alt+F6", "⇧⌘F5": "Shift+Alt+F5",
        "⌘,": "Alt+,", "⌘Q": "Alt+Q", "⇧⌘1": "Shift+Alt+1",
    ]

    /// Text with the Mac's shortcuts (runs of ⌃⌥⇧⌘ and a key) as Linux's.
    static func translatingMac(_ text: String) -> String {
        var result = text
        // Longest first, so ⇧⌥⌘← isn't taken as ⌥⌘←.
        for (mac, linux) in fromMac.sorted(by: { $0.key.count > $1.key.count }) {
            result = result.replacingOccurrences(of: mac, with: linux)
        }
        return result
    }
}
