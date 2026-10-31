import BeebCore
import BeebHost
import BeebNetwork
import CGtk
import Foundation
import Observation

private typealias RadioRows = PreferencesUI.RadioRows

/// Preferences (the Mac's Settings window): libadwaita's preferences
/// dialog, over the window in front, with a page for each of the Mac's
/// tabs. Opened again, the open one shows the page asked for.
@MainActor
enum PreferencesWindow {
    enum Page: String, CaseIterable {
        case general, keyboard, gamepad, debugging, games, networking
    }

    /// The dialog, while it's open.
    private static var open: PreferencesDialog?

    static func show(page: Page = .general) {
        if let open {
            open.show(page)
            open.bringForward()
            return
        }
        let dialog = PreferencesDialog(page: selfTestPage ?? page)
        open = dialog
        dialog.onClosed = { open = nil }
        dialog.present()
        if LaunchScreen.isSelfTest, UserDefaults.standard.bool(forKey: "MacBeebSelfTestPreferencesRecord") {
            dialog.keyboard.startRecording()
        }
        // `-MacBeebSelfTestPreferencesScroll YES`: the page's end, for a
        // window capture.
        if LaunchScreen.isSelfTest, UserDefaults.standard.bool(forKey: "MacBeebSelfTestPreferencesScroll") {
            MainLoop.after(1) { dialog.scrollToEnd() }
        }
    }

    /// `-MacBeebSelfTestPreferencesSample YES`: a window capture's things to
    /// show (custom keys, buttons held). Only with a configuration folder
    /// of the capture's own (XDG_CONFIG_HOME), as the keys are saved.
    private static func addSamples() {
        let settings = KeyboardSettings.shared
        settings.setMapping(keyCode: 0x69, macKeyName: "Print Screen", to: .copy)
        settings.setMapping(keyCode: 0x0A, macKeyName: "\\", to: .shiftLock)
        settings.setMapping(keyCode: 0x75, macKeyName: "Delete", to: .delete)
        if let disc = settings.editingDisc {
            settings.setMapping(keyCode: 0x06, macKeyName: "Z", to: .left, disc: disc)
            settings.setMapping(keyCode: 0x07, macKeyName: "X", to: .right, disc: disc)
            GamepadSettings.shared.setKey(.space, for: .b, disc: disc)
        }
        GamepadSettings.shared.held = [.a, .x, .leftShoulder]
    }

    /// `-MacBeebSelfTestPreferencesPage keyboard`: the page a window capture
    /// opens with (and `-MacBeebSelfTestPreferencesDisc path`, the disc
    /// whose settings it shows).
    private static var selfTestPage: Page? {
        guard LaunchScreen.isSelfTest else { return nil }
        let defaults = UserDefaults.standard
        if let disc = defaults.string(forKey: "MacBeebSelfTestPreferencesDisc") {
            KeyboardSettings.shared.editingDisc = disc
        }
        if defaults.bool(forKey: "MacBeebSelfTestPreferencesSample"),
           ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]?.hasPrefix("/tmp") == true {
            addSamples()
        }
        return defaults.string(forKey: "MacBeebSelfTestPreferencesPage").flatMap(Page.init(rawValue:))
    }
}

/// The dialog and its pages.
@MainActor
final class PreferencesDialog {
    let dialog: Dialog
    let keyboard: KeyboardPreferences
    var onClosed: () -> Void = {}

    init(page: PreferencesWindow.Page) {
        PreferencesStyles.install()
        dialog = Dialog(cast(adw_preferences_dialog_new()!) as WidgetPointer)
        adw_dialog_set_title(cast(dialog.widget), "Preferences")
        adw_dialog_set_content_width(cast(dialog.widget), 720)
        adw_dialog_set_content_height(cast(dialog.widget), 700)
        adw_preferences_dialog_set_search_enabled(cast(dialog.widget), 1)
        keyboard = KeyboardPreferences()
        let pages: [(PreferencesWindow.Page, PreferencesPage)] = [
            (.general, GeneralPreferences().page),
            (.keyboard, keyboard.page),
            (.gamepad, GamepadPreferences().page),
            (.debugging, DebuggingPreferences().page),
            (.games, GamesPreferences().page),
            (.networking, NetworkingPreferences().page),
        ]
        for (name, page) in pages {
            adw_preferences_page_set_name(cast(page.widget), name.rawValue)
            adw_preferences_dialog_add(cast(dialog.widget), cast(page.widget))
        }
        keyboard.dialog = self
        show(page)
        dialog.keep(self)
        dialog.onClosed { [self] in
            keyboard.stopRecording()
            onClosed()
        }
        // (Its window closing takes it too, without its closing.)
        dialog.onDestroy { [self] in onClosed() }
    }

    /// Over the window in front (or, with none, the first there is).
    func present() {
        let parent = Application.shared.activeWindow
            ?? Application.shared.windows.first { gtk_widget_get_visible(cast($0)) != 0 }.map { cast($0) }
        dialog.present(over: parent.map(Widget.init))
    }

    func show(_ page: PreferencesWindow.Page) {
        adw_preferences_dialog_set_visible_page_name(cast(dialog.widget), page.rawValue)
    }

    /// The page showing, scrolled to its end.
    func scrollToEnd() {
        guard let page = adw_preferences_dialog_get_visible_page(cast(dialog.widget)),
              let scroller = gtk_widget_get_first_child(cast(page)),
              let adjustment = gtk_scrolled_window_get_vadjustment(cast(scroller)) else { return }
        gtk_adjustment_set_value(adjustment, gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
    }

    /// Its window to the front (asked for again from another window).
    func bringForward() {
        if let root = dialog.root {
            gtk_window_present(cast(root))
        }
    }

    /// A brief message, with a button (Undo, say).
    func toast(_ message: String, button: String? = nil, action: (@MainActor () -> Void)? = nil) {
        let toast = adw_toast_new(message)!
        adw_toast_set_timeout(toast, 5)
        if let button, let action {
            adw_toast_set_button_label(toast, button)
            GObjectRef(toast).on("button-clicked", action)
        }
        adw_preferences_dialog_add_toast(cast(dialog.widget), toast)
    }
}

// MARK: General

/// What MacBeeb opens with.
@MainActor
final class GeneralPreferences {
    let page = PreferencesPage(title: "General", icon: "preferences-system-symbolic")

    init() {
        let setting = PreferencesUI.LaunchSetting.shared
        let screens = LaunchScreen.allCases
        let choices = RadioRows(screens.map { ($0.title, nil) }, selected: screens.firstIndex(of: setting.value) ?? 0) {
            setting.value = screens[$0]
        }
        let group = PreferencesGroup(title: "When MacBeeb opens, show")
        choices.add(to: group)
        group.add(PreferencesUI.footnote("The welcome screen leads to everything: a BBC Micro, the Game Library and the Network Studio. With it, closing your last window brings it back, and closing it quits MacBeeb. Opening with the Game Library suits playing games: choose one and its BBC Micro opens, set up to play it. The Network Studio opens the network you used last. Takes effect the next time MacBeeb opens; Welcome to MacBeeb, in the main menu, shows the welcome screen any time."))
        page.add(group)
        page.track { choices.set(screens.firstIndex(of: setting.value) ?? 0) }
    }
}

// MARK: Debugging

/// The debug adapter: whether editors can debug the BBC, and on which port.
@MainActor
final class DebuggingPreferences {
    let page = PreferencesPage(title: "Debugging", icon: "applications-engineering-symbolic")

    init() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: MachineController.debugAdapterEnabledKey) as? Bool ?? true
        let saved = defaults.integer(forKey: MachineController.debugAdapterPortKey)
        let port = PreferencesUI.portRow("Port", value: Double(saved == 0 ? 6502 : saved)) { value in
            let defaults = UserDefaults.standard
            let current = defaults.integer(forKey: MachineController.debugAdapterPortKey)
            if Int(value) != (current == 0 ? 6502 : current) {
                defaults.set(Int(value), forKey: MachineController.debugAdapterPortKey)
            }
        }
        port.isEnabled = enabled
        let toggle = SwitchRow("Let editors debug the BBC (Debug Adapter Protocol)", isOn: enabled) { on in
            UserDefaults.standard.set(on, forKey: MachineController.debugAdapterEnabledKey)
            port.isEnabled = on
        }
        let adapter = PreferencesGroup {
            toggle
            port
        }
        adapter.add(PreferencesUI.footnote("VS Code and other editors that speak DAP connect to localhost on this port, to set breakpoints in your source, step, and inspect the machine. Changes take effect next launch."))

        let marketplace = ActionRow("The MacBeeb extension", subtitle: "Visual Studio Marketplace")
            .suffix(Icon("adw-external-link-symbolic").style("dim-label"))
            .onActivated { Platform.open(VSCodeExtension.marketplace) }
        marketplace.tooltip(VSCodeExtension.marketplace.absoluteString)
        let guide = ActionRow("How to use it", subtitle: "Debugging with VS Code Guide")
            .suffix(Icon("go-next-symbolic").style("dim-label"))
            .onActivated { GuideWindow.show(page: "vscode") }
        let vscode = PreferencesGroup(title: "VS Code") {
            marketplace
            guide
        }
        page.add(adapter)
        page.add(vscode)
    }
}

extension PreferencesUI {
    /// A spin row for a port: a whole number, shown as it is (6502, not
    /// 6,502).
    static func portRow(_ title: String, value: Double, _ changed: @escaping @MainActor (Double) -> Void) -> SpinRow {
        let row = SpinRow(title, value: value, range: 1...65535, step: 1)
        adw_spin_row_set_numeric(cast(row.widget), 1)
        adw_spin_row_set_digits(cast(row.widget), 0)
        // (Only the user's changes, not setting it up.)
        let pointer = row.widget
        row.object.onChange("value") { changed(adw_spin_row_get_value(cast(pointer))) }
        return row
    }
}

// MARK: Games

/// The BBC Micro Classics bookshelf: whether, and where, to look for
/// downloaded games.
@MainActor
final class GamesPreferences {
    let page = PreferencesPage(title: "Games", icon: "applications-games-symbolic")

    init() {
        let classics = ClassicsLibrary.shared
        let toggle = SwitchRow("Add downloaded Classics automatically",
                               subtitle: "When you get a game from BBCMicro.co.uk, MacBeeb looks for the disc image in this folder and adds it to the bookshelf once the download finishes. It only reads the folder, only while MacBeeb is open, and never changes your downloads.",
                               isOn: classics.autoDetect == true) { on in
            if classics.autoDetect != on { classics.autoDetect = on }
        }
        let folder = ActionRow("Folder")
        let useDownloads = Button("Use Downloads") { classics.downloadFolder = ClassicsLibrary.defaultDownloadFolder }
            .align(vertical: GTK_ALIGN_CENTER)
        let choose = Button("Choose…") {
            FileDialogs.chooseFolder(title: "Choose the folder your browser saves downloads to",
                                     initial: classics.downloadFolder) { url in
                if let url { classics.downloadFolder = url }
            }
        }
        .align(vertical: GTK_ALIGN_CENTER)
        folder.prefix(Icon("folder-download-symbolic")).suffix(useDownloads).suffix(choose)
        let statusIcon = Icon("object-select-symbolic")
        let status = ActionRow("Looking for downloaded games").prefix(statusIcon)
        let group = PreferencesGroup {
            toggle
            folder
            status
        }
        group.add(PreferencesUI.footnote("You can always add games with Import Disc… on the bookshelf, or by dragging disc images onto it."))
        page.add(group)

        page.track {
            toggle.isOn = classics.autoDetect == true
            let path = classics.downloadFolder.path
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            folder.subtitle = path.hasPrefix(home + "/") ? "~/" + path.dropFirst(home.count + 1) : path
            folder.tooltip(path)
            useDownloads.isVisible = classics.downloadFolder.standardizedFileURL
                != ClassicsLibrary.defaultDownloadFolder.standardizedFileURL
            switch classics.watchState {
            case .off:
                status.isVisible = false
            case .watching:
                status.isVisible = true
                status.title = "Looking for downloaded games"
                status.subtitle = ""
                statusIcon.name = "object-select-symbolic"
                statusIcon.removeStyle("warning")
                statusIcon.style("success")
            case .noAccess(let reason):
                status.isVisible = true
                status.title = "MacBeeb can’t read this folder"
                status.subtitle = "\(reason) Choose another folder."
                statusIcon.name = "dialog-warning-symbolic"
                statusIcon.removeStyle("success")
                statusIcon.style("warning")
            }
        }
    }
}

// MARK: Networking

/// Which Internet Econet service rooms are made and codes looked up on.
@MainActor
final class NetworkingPreferences {
    let page = PreferencesPage(title: "Networking", icon: "web-browser-symbolic")
    private var custom = !InternetEconetService.isOfficial
    private var testing = false

    private var choices: RadioRows!
    private let address = EntryRow("Address", text: InternetEconetService.isOfficial ? "" : InternetEconetService.current.absoluteString)
    private let problem = Label("", style: "error").wrap()
    private let developer = Label("Developer mode: an unencrypted service on this \(Platform.keyboardName).", style: "warning").wrap()
    private static let testDetail = "Whether MacBeeb can use the service"
    private let testRow = ActionRow("Connection", subtitle: testDetail)
    private let testButton = Button("Test Connection")
    private let spinner = Spinner()
    private let resultIcon = Icon("object-select-symbolic")
    private let reset = Button("Reset to Default").style("flat")

    init() {
        let official = InternetEconetService.officialURL.host ?? ""
        choices = RadioRows([("Official service (\(official))", nil), ("Custom service", nil)], selected: custom ? 1 : 0) {
            [self] index in choose(custom: index == 1)
        }
        let group = PreferencesGroup(title: "Internet Econet Service").headerSuffix(reset)
        choices.add(to: group)
        group.add(address)
        group.add(testRow)
        problem.margin(top: 12)
        developer.margin(top: 12)
        group.add(problem)
        group.add(developer)
        group.add(PreferencesUI.footnote("Sharing a network over the Internet makes its room here, and join codes are looked up here. Anyone can run a compatible service of their own (cloudflare-econet, on Cloudflare); invitation links name theirs. Each service keeps its own rooms and credentials."))
        let link = Label(markup: "<a href=\"https://github.com/acorn-playground/cloudflare-econet\">cloudflare-econet on GitHub</a>")
        link.margin(top: 6)
        group.add(link)
        page.add(group)

        address.onApply { [self] _ in apply() }
        address.object.on("changed") { [self] in
            address.removeStyle("error")
            refresh()
        }
        testButton.align(vertical: GTK_ALIGN_CENTER).onClicked { [self] in test() }
        testRow.suffix(resultIcon).suffix(spinner).suffix(testButton)
        spinner.isVisible = false
        resultIcon.isVisible = false
        reset.onClicked { [self] in
            choices.set(0)
            choose(custom: false)
            address.text = ""
        }
        // (The page keeps this object, which its rows' handlers reach.)
        page.keep(self)
        refresh()
        // `-MacBeebSelfTestPreferencesService address`: a window capture's
        // custom service (tested, with -MacBeebSelfTestPreferencesServiceTest).
        if LaunchScreen.isSelfTest, let service = UserDefaults.standard.string(forKey: "MacBeebSelfTestPreferencesService") {
            choices.set(1)
            choose(custom: true)
            address.text = service
            if UserDefaults.standard.bool(forKey: "MacBeebSelfTestPreferencesServiceTest") { test() }
        }
    }

    private func choose(custom: Bool) {
        guard custom != self.custom else { return }
        self.custom = custom
        clearResult()
        if !custom {
            InternetEconetService.current = InternetEconetService.officialURL
            address.removeStyle("error")
        }
        refresh()
        if custom { address.grabFocus() }
    }

    private func refresh() {
        address.isVisible = custom
        reset.isEnabled = custom
        if !custom { problem.isVisible = false }
        if custom, let url = try? InternetEconetService.validate(address.text).get(), InternetEconetService.isLocalDevelopment(url) {
            developer.isVisible = true
        } else {
            developer.isVisible = false
        }
        testButton.isEnabled = !testing && !(custom && address.text.isEmpty)
    }

    private func clearResult() {
        resultIcon.isVisible = false
        testRow.subtitle = Self.testDetail
    }

    /// Takes the typed address, if it's a good one.
    @discardableResult
    private func apply() -> URL? {
        guard custom else { return InternetEconetService.officialURL }
        switch InternetEconetService.validate(address.text) {
        case .success(let url):
            problem.isVisible = false
            address.removeStyle("error")
            address.text = url.absoluteString
            InternetEconetService.current = url
            return url
        case .failure(let error):
            problem.text = error.description
            problem.isVisible = true
            address.style("error")
            return nil
        }
    }

    private func test() {
        guard !testing, let url = apply() else { return }
        testing = true
        clearResult()
        spinner.isVisible = true
        testRow.subtitle = "Testing…"
        refresh()
        Task { @MainActor in
            let ok: Bool, text: String
            do {
                let info = try await RoomAPI(service: url).serviceInfo()
                if let incompatibility = info.incompatibility {
                    (ok, text) = (false, incompatibility)
                } else {
                    (ok, text) = (true, "\(info.name): compatible, protocol \(ServiceInfo.protocolVersion)")
                }
            } catch {
                (ok, text) = (false, "No Internet Econet service answered at \(url.host ?? url.absoluteString)")
            }
            testing = false
            spinner.isVisible = false
            refresh()
            testRow.subtitle = text
            resultIcon.name = ok ? "object-select-symbolic" : "dialog-error-symbolic"
            resultIcon.removeStyle(ok ? "error" : "success")
            resultIcon.style(ok ? "success" : "error")
            resultIcon.isVisible = true
            macbeeb_announce(testRow.widget, text)
        }
    }
}
