import CGtk
import Foundation

/// The guides in docs/hardware-expansions (and the Network Studio's),
/// shown in the app. Installed, they're in share/macbeeb/guides; run from
/// the source tree, they're read from docs/ directly, so they're never out
/// of step. (The Mac's is Guide, in its GuideWindow.)
@MainActor
enum GuidePages {
    struct Page {
        var id: String
        var title: String
        var icon: String
    }

    /// In reading order, each with its icon (the Mac's SF Symbols, in
    /// GNOME's icons).
    static let order: [(String, String)] = [
        ("README", "accessories-dictionary-symbolic"),
        ("rom-sockets", "application-x-firmware-symbolic"),
        ("sideways-ram", "media-flash-symbolic"),
        ("watford-shadow-ram", "view-dual-symbolic"),
        ("aries-b32-b12", "view-continuous-symbolic"),
        ("videonula", "preferences-color-symbolic"),
        ("developer-reference", "text-x-generic-symbolic"),
        ("vscode", "accessories-text-editor-symbolic"),
        ("network-studio", "network-workgroup-symbolic"),
        ("ai-agents", "utilities-terminal-symbolic"),
    ]

    static let folder: URL? = AppResources.file(installed: "guides/hardware-expansions", source: "docs/hardware-expansions")

    static let pages: [Page] = order.compactMap { id, icon in
        guard let text = text(id) else { return nil }
        let title = text.split(separator: "\n").first { $0.hasPrefix("# ") }
            .map { HelpMarkdown.plain(String($0.dropFirst(2))) } ?? id
        return Page(id: id, title: title, icon: icon)
    }

    static func text(_ id: String) -> String? {
        guard let folder else { return nil }
        var url = folder.appendingPathComponent("\(id).md")
        // The Network Studio's guide lives in its own folder in the source.
        if id == "network-studio" && !FileManager.default.fileExists(atPath: url.path) {
            url = folder.deletingLastPathComponent().appendingPathComponent("network-studio/README.md")
        }
        // (The guides quote the Mac's shortcuts: shown as Linux's.)
        return (try? String(contentsOf: url, encoding: .utf8)).map(Shortcuts.translatingMac)
    }

    static func page(_ id: String) -> Page? {
        pages.first { $0.id == id }
    }
}

/// Help > Hardware Expansion Guide (and the Network Studio, AI Agents and
/// VS Code guides): the pages in a sidebar, the one chosen beside it, with
/// links between them, and Back.
@MainActor
final class GuideWindow {
    let window: Window
    private static var current: GuideWindow?

    private let split: NavigationSplitView
    private let sidebar = ListBox(selection: GTK_SELECTION_SINGLE)
    private let pageTitle = WindowTitle("Hardware Expansion Guide")
    private let scroller: ScrolledWindow
    private let document = Bin()
    private let backAction: Action
    private var page: String?
    private var history: [String] = []
    private var anchors: [String: Widget] = [:]
    /// The sidebar's selection set by the window, not the user.
    private var selecting = false
    /// Pages shown so far (a page's widgets go when the next is shown).
    private var shown = 0

    /// Opens the guide at `page` (a file name without .md, perhaps with
    /// "#anchor"), or brings it forward there.
    static func show(page: String) {
        let page = page.isEmpty ? nil : page
        if let current, Windows.existing("guide") != nil {
            current.window.present()
            if let page { current.follow(page) }
            current.split.showContent()
            return
        }
        Windows.show("guide") {
            let guide = GuideWindow(page: page)
            current = guide
            return guide.window
        }
        current?.focusSidebar()
    }

    private init(page initial: String?) {
        window = Window(title: "Hardware Expansion Guide", width: 1000, height: 720)
        window.minimumSize(width: 360, height: 360)

        let clamp = Clamp(document, maximum: 760)
        adw_clamp_set_tightening_threshold(cast(clamp.widget), 600)
        clamp.margin(top: 24, bottom: 40, start: 24, end: 24)
        scroller = HelpDocument.scroller(clamp)

        let back = Button(icon: "go-previous-symbolic").tooltip("Back").accessibleLabel("Back").action("win.back")
        let contentHeader = HeaderBar(title: pageTitle).start(back)
        let content = ToolbarView(content: scroller).top(contentHeader)

        sidebar.style("navigation-sidebar")
        for entry in GuidePages.pages {
            let row = Box(.horizontal, spacing: 12) {
                Icon(entry.icon)
                Label(entry.title).ellipsize().tooltip(entry.title)
            }
            sidebar.append(row)
        }
        let sidebarPage = ToolbarView(content: ScrolledWindow(sidebar, horizontal: GTK_POLICY_NEVER))
            .top(HeaderBar(title: WindowTitle("Guides")))
        split = NavigationSplitView(sidebar: sidebarPage, sidebarTitle: "Guides", content: content,
                                    contentTitle: "Hardware Expansion Guide")
            .sidebarWidth(minimum: 220, maximum: 320, fraction: 0.3)
        window.content = split

        // Narrow, the sidebar and the page take turns.
        let narrow = macbeeb_breakpoint("max-width: 600sp")!
        macbeeb_help_breakpoint_set_bool(narrow, gpointer(split.widget), "collapsed", 1)
        // (The split view's own back button, to the sidebar, is there then;
        // Alt+Left still goes back a page.)
        macbeeb_breakpoint_hide(narrow, back.widget)
        adw_application_window_add_breakpoint(cast(window.widget), narrow)

        // (Its handler's connected below, once self is whole.)
        backAction = Action("back") {}
        window.add(backAction)
        App.addStandardShortcuts(to: window)
        window.shortcut("<Alt>Left", action: "win.back")
        // The mouse's back button.
        let mouseBack = ClickGesture(button: 8)
        window.add(mouseBack)

        window.keep(self)
        window.onDestroy { Self.current = nil }
        GObjectRef(backAction.gAction).onPointer("activate") { [weak self] _ in self?.goBack() }
        mouseBack.onPressed { [weak self] _, _, _ in self?.goBack() }
        sidebar.onSelect { [weak self] index in
            guard let self, !self.selecting, let index, GuidePages.pages.indices.contains(index) else { return }
            self.go(to: GuidePages.pages[index].id, anchor: nil, record: true)
            self.split.showContent()
        }

        if GuidePages.pages.isEmpty {
            content.content = StatusPage(icon: "accessories-dictionary-symbolic", title: "No guide",
                                         description: "The guides weren’t found in the app.")
            backAction.isEnabled = false
            return
        }
        if let initial {
            follow(initial, record: false)
        }
        if page == nil, let first = GuidePages.pages.first {
            go(to: first.id, anchor: nil, record: false)
        }
        if initial != nil { split.showContent() }
    }

    /// Focus on the page chosen in the sidebar (rather than on the first
    /// of the page's text, which would select it).
    private func focusSidebar() {
        if let row = gtk_list_box_get_selected_row(cast(sidebar.widget)) {
            gtk_widget_grab_focus(cast(row))
        }
    }

    // MARK: Pages

    /// A link: "rom-sockets.md", "sideways-ram.md#with-a-shadow-ram-board",
    /// "#elite-over-econet", or a page's name. False if it isn't a guide's.
    @discardableResult
    func follow(_ link: String, record: Bool = true) -> Bool {
        if link.contains("://") || link.hasPrefix("mailto:") { return false }
        let parts = link.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let name = ((parts[0] as NSString).lastPathComponent as NSString).deletingPathExtension
        let anchor = parts.count > 1 && !parts[1].isEmpty ? parts[1].lowercased() : nil
        let id = name.isEmpty ? page : name
        guard let id, GuidePages.page(id) != nil else { return false }
        go(to: id, anchor: anchor, record: record)
        return true
    }

    private func go(to id: String, anchor: String?, record: Bool) {
        if id != page {
            if record, let page { history.append(page) }
            show(id)
        }
        if let anchor {
            scroll(to: anchor)
        }
    }

    private func goBack() {
        guard let previous = history.popLast() else { return }
        show(previous)
    }

    private func show(_ id: String) {
        guard let entry = GuidePages.page(id), let text = GuidePages.text(id) else { return }
        page = id
        shown += 1
        let renderer = HelpDocument(base: GuidePages.folder) { [weak self] uri in self?.follow(uri) ?? false }
        document.child = renderer.view(HelpMarkdown.parse(text))
        anchors = renderer.anchors
        scroller.scrollToTop()
        pageTitle.title = entry.title
        window.title = entry.title
        if let content = adw_navigation_split_view_get_content(cast(split.widget)) {
            adw_navigation_page_set_title(content, entry.title)
        }
        backAction.isEnabled = !history.isEmpty
        if let index = GuidePages.pages.firstIndex(where: { $0.id == id }), sidebar.selectedIndex != index {
            selecting = true
            sidebar.select(index)
            selecting = false
        }
    }

    /// Scrolls to a heading once the page is laid out (a frame or two
    /// after it's made), unless another page has taken its place.
    private func scroll(to anchor: String) {
        guard let target = anchors[anchor] else { return }
        let content = document
        let adjustment = gtk_scrolled_window_get_vadjustment(cast(scroller.widget))
        let showing = shown
        var frames = 0
        scroller.onTick { [weak self] _ in
            guard let self, self.shown == showing else { return false }
            frames += 1
            var origin = graphene_point_t(x: 0, y: 0), point = graphene_point_t(x: 0, y: 0)
            guard frames > 1, gtk_widget_get_height(target.widget) > 0,
                  gtk_widget_compute_point(target.widget, content.widget, &origin, &point) != 0 else {
                return frames < 60
            }
            // (The clamp's margin above the document, less a little air.)
            gtk_adjustment_set_value(adjustment, Double(point.y) + 24 - 12)
            return false
        }
    }
}
