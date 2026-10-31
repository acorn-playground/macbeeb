import BeebCore
import BeebHost
import CGtk
import Foundation

/// About MacBeeb: libadwaita's about dialog, with the project, its author,
/// its licence and its credits.
@MainActor
enum AboutDialog {
    static let repository = URL(string: "https://github.com/acorn-playground/macbeeb")!
    static let website = URL(string: "https://jamesdrandall.com")!

    static func show() {
        let dialog = adw_about_dialog_new()!
        let about = OpaquePointer(dialog)
        adw_about_dialog_set_application_name(about, "MacBeeb")
        adw_about_dialog_set_application_icon(about, App.id)
        adw_about_dialog_set_version(about, Platform.appVersion)
        adw_about_dialog_set_developer_name(about, "James Randall")
        adw_about_dialog_set_website(about, repository.absoluteString)
        adw_about_dialog_set_issue_url(about, repository.appendingPathComponent("issues").absoluteString)
        adw_about_dialog_set_comments(about, "A cycle-exact BBC Micro emulator.")
        adw_about_dialog_set_copyright(about, "© James Randall")
        adw_about_dialog_set_license_type(about, GTK_LICENSE_GPL_3_0)
        adw_about_dialog_add_link(about, "jamesdrandall.com", website.absoluteString)
        // (The strings live only as long as the closure.)
        withCStringArray(["b2 by Tom Seddon https://github.com/tom-seddon/b2",
                          "BeebEm by Dave Gilbert, Mike Wyatt, Chris Needham and others https://github.com/stardot/beebem-windows",
                          "jsbeeb by Matt Godbolt and its contributors https://github.com/mattgodbolt/jsbeeb"]) {
            adw_about_dialog_add_acknowledgement_section(about, "Built on the work of", $0)
        }
        adw_about_dialog_add_legal_section(about, "BeebAsm", nil, GTK_LICENSE_GPL_3_0, nil)
        adw_about_dialog_add_legal_section(about, "Baron", nil, GTK_LICENSE_MIT_X11, nil)
        // What's new in this release (the newest in the release notes).
        if let release = WhatsNew.releases.first {
            adw_about_dialog_set_release_notes_version(about, release.version)
            adw_about_dialog_set_release_notes(about, releaseNotes(release))
        }
        if let text = CreditsWindow.text {
            adw_about_dialog_add_legal_section(about, "Credits", nil, GTK_LICENSE_CUSTOM,
                                               Markup.escape(text))
        }
        adw_dialog_present(cast(dialog), Application.shared.activeWindow)
    }
}

extension AboutDialog {
    /// A release's notes as the About dialog takes them (AppStream's
    /// markup: paragraphs and a list), its Markdown made plain text.
    static func releaseNotes(_ release: WhatsNew.Release) -> String {
        func plain(_ text: String) -> String {
            var text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            for mark in ["**", "__", "`", "*", "_"] { text = text.replacingOccurrences(of: mark, with: "") }
            return Markup.escape(text)
        }
        let intro = release.intro.map { "<p>\(plain($0))</p>" }.joined()
        let items = release.items.isEmpty ? "" : "<ul>" + release.items.map { "<li>\(plain($0))</li>" }.joined() + "</ul>"
        return intro + items
    }
}

/// Help > Keyboard Shortcuts: libadwaita's shortcuts dialog. In a machine
/// window Alt plays the Mac's Command key's part, and Control is the BBC's.
@MainActor
enum ShortcutsDialog {
    static func show() {
        let dialog = adw_shortcuts_dialog_new()!
        func section(_ title: String, _ items: [(String, String)]) {
            let section = adw_shortcuts_section_new(title)!
            for (label, accelerator) in items {
                adw_shortcuts_section_add(section, adw_shortcuts_item_new(label, accelerator))
            }
            adw_shortcuts_dialog_add(cast(dialog), section)
        }
        section("Discs and Tapes", [
            ("Open and boot a disc", "<Alt>o"), ("Insert a disc in drive 0", "<Alt><Shift>o"),
            ("New disc", "<Alt>n"), ("Show disc contents", "<Alt><Shift>i"), ("Load a tape", "<Alt>t"),
        ])
        section("Saving", [
            ("Save a screenshot", "<Alt>s"), ("Copy the screen", "<Alt>c"), ("Paste text into the BBC", "<Alt>v"),
            ("Save state", "<Alt><Shift>s"), ("Load state", "<Alt><Shift>l"), ("Quick save", "<Alt><Shift>F6"),
            ("Quick load", "<Alt><Shift>F5"), ("Start or stop recording", "<Alt>r"),
        ])
        section("The Machine", [
            ("Pause or resume", "<Alt>p"), ("Full speed", "<Alt>f"), ("Break", "<Alt>b"),
            ("Shift-Break (boot the disc)", "<Alt><Shift>b"), ("Ctrl-Break (hard reset)", "<Alt><Control>b"),
            ("Power cycle", "<Alt><Shift>r"), ("Capture or release the mouse", "<Alt>m"),
            ("Release a captured mouse", "<Alt>Escape"), ("Rewind 5 seconds", "<Alt>Left"),
            ("Rewind timeline", "<Alt><Shift>Left"), ("Hardware", "<Alt>e"),
        ])
        section("View", [
            ("Actual size", "<Alt>0"), ("Zoom in", "<Alt>equal"), ("Zoom out", "<Alt>minus"), ("Full screen", "F11"),
        ])
        section("Debugging", [
            ("Show the debugger", "<Alt>d"), ("Break into the debugger, or continue", "<Alt>y"),
            ("Step over, into, out (in the debugger)", "F6 F7 F8"), ("Step back (in the debugger)", "<Shift>F7"),
        ])
        section("MacBeeb", [
            ("New BBC Micro window", "<Alt><Control>n"), ("Game library", "<Alt><Shift>k"), ("Preferences", "<Alt>comma"),
            ("Keyboard shortcuts", "<Alt>question"), ("Close the window", "<Alt>w"), ("Quit", "<Alt>q"),
        ])
        section("Networks and Agents", [
            ("New network", "<Alt><Shift>n"), ("Join an Econet network", "<Alt><Shift>j"),
            ("Network Studio", "<Alt><Control>0"), ("Print Centre", "<Alt><Control>p"),
            ("AI agents’ activity log", "<Alt><Control>l"),
        ])
        adw_dialog_present(cast(dialog), Application.shared.activeWindow)
    }
}

/// Machine > Rewind Timeline: the last minute's snapshots, to go back to.
/// (The Mac's RewindSheet.)
@MainActor
final class RewindDialog {
    let machine: MachineController
    private var points: [UInt64] = []
    private var now: UInt64 = 0
    private var wasPaused = false
    private let picture = Picture()
    private let caption = Label("", style: "dim-label", "numeric")
    private let slider = Scale(value: 0, range: 0...1)
    private var dialog: Dialog?

    init(machine: MachineController) {
        self.machine = machine
    }

    func present(over window: Window) {
        wasPaused = machine.paused
        machine.setPaused(true)
        picture.size(width: 368, height: 288).pixelated().style("card")
        caption.centred()
        slider.drawValue(false).expand(horizontal: true)
        let rewind = Button("_Rewind to Here") { [weak self] in self?.rewind() }
            .style("suggested-action", "pill")
        let cancel = Button("_Cancel") { [weak self] in self?.dialog?.close() }
            .style("pill")
        let empty = Label("No history yet: rewind keeps the last minute as the machine runs.", style: "dim-label").wrap().centred()
        let body = Box(.vertical, spacing: 12) {
            picture
            slider
            caption
            empty
            Box(.horizontal, spacing: 12) { cancel; rewind }.align(horizontal: GTK_ALIGN_CENTER).margin(top: 6)
        }
        .margin(top: 6, bottom: 24, start: 24, end: 24)
        let content = ToolbarView(content: body).top(HeaderBar())
        let dialog = Dialog(title: "Rewind", content: content, width: 440)
        self.dialog = dialog
        dialog.defaultWidget(rewind)
        dialog.onClosed { [weak self] in
            guard let self else { return }
            self.machine.setPaused(self.wasPaused)
            self.machine.showingTimeline = false
        }
        slider.object.on("value-changed") { [weak self] in self?.showPoint() }
        dialog.keep(self)
        dialog.present(over: window)

        Task {
            (points, now) = await machine.rewindPoints()
            let count = points.count
            empty.isVisible = count < 2
            slider.isVisible = count > 1
            caption.isVisible = count > 1
            rewind.isEnabled = count > 1
            if count > 1 {
                gtk_range_set_range(cast(slider.widget), 0, Double(count - 1))
                gtk_range_set_increments(cast(slider.widget), 1, 5)
                gtk_range_set_round_digits(cast(slider.widget), 0)
                slider.value = Double(count - 1)
            }
            showPoint()
        }
    }

    private var index: Int { Int(slider.value.rounded()) }

    private func showPoint() {
        let index = index
        if points.indices.contains(index) {
            let back = Double(now - min(now, points[index])) / 2_000_000
            caption.text = back < 0.05 ? "Now" : String(format: "%.1f seconds ago", back)
        }
        Task {
            guard let pixels = await machine.rewindThumbnailPixels(index), index == self.index else { return }
            picture.image = Platform.image(pixels: pixels, width: Rewinder.thumbnailWidth, height: Rewinder.thumbnailHeight)
        }
    }

    private func rewind() {
        if points.indices.contains(index) {
            machine.seek(to: points[index])
        }
        dialog?.close()
    }
}

/// File > New Disc…: the disc's format, its title, and which drive to put
/// it in, then where to save it. (On the Mac these are in the save panel;
/// GNOME's file chooser takes no extra controls.)
@MainActor
final class NewDiscPanel {
    struct Choice {
        var url: URL
        var kind: BlankDisc
        var title: String
        /// nil: don't put it in a drive.
        var drive: Int?
    }

    private static let formatDefaultsKey = "MacBeebNewDiscFormat"
    private let model: BBCMicro.Model
    private let emptyDrives: [Int]

    init(model: BBCMicro.Model, emptyDrives: [Int]) {
        self.model = model
        self.emptyDrives = emptyDrives
    }

    /// Shows the dialog; `completion` gets the choice (nil if cancelled).
    func present(_ completion: @escaping @MainActor (Choice?) -> Void) {
        let kinds = BlankDisc.allCases
        let saved = UserDefaults.standard.string(forKey: Self.formatDefaultsKey).flatMap(BlankDisc.init(rawValue:))
        let initial = saved ?? (model == .masterCompact ? .adfsL : .dfs80)
        let format = ComboRow("Format", items: kinds.map(\.name), selected: kinds.firstIndex(of: initial) ?? 0)
        let title = EntryRow("Title")
        let drive = ComboRow("Put In", items: ["Drive 0", "Drive 1", "Neither (Just Save It)"],
                             selected: emptyDrives.first ?? 1)
        func kind() -> BlankDisc { kinds[max(0, format.selected)] }
        title.object.on("changed") {
            let text = title.text
            // Within what the format holds.
            let limit = kind().maxTitleLength
            if text.count > limit {
                title.text = String(text.prefix(limit))
                gtk_widget_error_bell(title.widget)
            }
        }
        format.object.onChange("selected") {
            title.text = String(title.text.prefix(kind().maxTitleLength))
        }
        var finished = false
        let create = Button("C_reate…").style("suggested-action", "pill")
        let group = PreferencesGroup(description: "A blank disc, formatted and ready to save to.") {
            format
            title
            drive
        }
        let body = Box(.vertical, spacing: 24) {
            group
            create.align(horizontal: GTK_ALIGN_CENTER)
        }
        .margin(top: 12, bottom: 24, start: 24, end: 24)
        let dialog = Dialog(title: "New Disc", content: ToolbarView(content: body).top(HeaderBar()), width: 460)
        dialog.defaultWidget(create)
        dialog.onClosed {
            if !finished { completion(nil) }
        }
        create.onClicked {
            let kind = kind()
            let name = "Blank Disc.\(kind.format.rawValue)"
            Platform.chooseSaveLocation(.discs, suggestedName: name, message: "New Disc") { url in
                guard var url else { return }
                if url.pathExtension.isEmpty { url.appendPathExtension(kind.format.rawValue) }
                UserDefaults.standard.set(kind.rawValue, forKey: Self.formatDefaultsKey)
                var name = title.text
                if name.isEmpty {
                    name = url.deletingPathExtension().lastPathComponent
                }
                let index = drive.selected
                finished = true
                dialog.close()
                completion(Choice(url: url, kind: kind, title: name, drive: index < 2 ? index : nil))
            }
        }
        dialog.present(over: Application.shared.activeWindow.map(Widget.init))
    }
}

/// Pango markup.
enum Markup {
    static func escape(_ text: String) -> String {
        String(gOwned: g_markup_escape_text(text, -1)) ?? text
    }
}
