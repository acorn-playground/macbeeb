import BeebLibrary
import CGtk
import Foundation

/// The shelves of the game library, one to a tab.
enum LibraryShelf: String, CaseIterable {
    /// BBCMicro.co.uk's top 20.
    case classics
    /// MacBeeb's author's favourites, also from BBCMicro.co.uk.
    case authorsPicks
    /// The user's own.
    case myGames

    var name: String {
        switch self {
        case .classics: "BBC Micro Classics"
        case .authorsPicks: "Author’s Picks"
        case .myGames: "My Games"
        }
    }

    var icon: String {
        switch self {
        case .classics: "starred-symbolic"
        case .authorsPicks: "user-bookmarks-symbolic"
        case .myGames: "media-floppy-symbolic"
        }
    }

    /// The tab shown last time (the Mac's, too).
    static let defaultsKey = "MacBeebLibraryTab"
}

/// The game library: the BBC Micro Classics (BBCMicro.co.uk's top 20 games
/// and a book for the archive itself), the Author's Picks and My Games, in
/// tabs. Games from the archive are downloaded from its pages in the user's
/// browser; MacBeeb never downloads them itself. A game on both archive
/// shelves is the same game, installed once. (The Mac's BookshelfView.)
@MainActor
enum BookshelfWindow {
    static let key = "bookshelf"
    static let title = "Game Library"

    static func show() {
        watch()
        Windows.show(key) { BookshelfController().window }
    }

    /// The open window's controller.
    fileprivate(set) static weak var controller: BookshelfController?

    private static var watches: [AnyObject] = []

    /// For the app's start: brings the library forward when a download
    /// arrives (whichever windows are open) and reads the covers in the
    /// background, ready for it.
    static func startWatching() {
        watch()
        ShelfCoverCache.preload()
    }

    /// Brings the library to the front when a download arrives (opening it
    /// if need be), and to My Games when there's a disc or picture to
    /// make one of. Opening an already-open library just raises it.
    private static func watch() {
        guard watches.isEmpty else { return }
        LibraryStyles.install()
        let classics = ClassicsLibrary.shared
        let counts = Counts(arrivals: classics.arrivals, drafts: classics.drafts.count)
        watches.append(LibraryWatch({ classics.arrivals }) { arrivals in
            guard arrivals != counts.arrivals else { return }
            counts.arrivals = arrivals
            // (Not while state's being followed: a window's built after.)
            MainLoop.after(0) { show() }
        })
        watches.append(LibraryWatch({ classics.drafts.count }) { drafts in
            defer { counts.drafts = drafts }
            guard drafts > counts.drafts else { return }
            MainLoop.after(0) {
                show()
                controller?.showShelf(.myGames)
            }
        })
    }

    @MainActor
    private final class Counts {
        var arrivals: Int
        var drafts: Int
        init(arrivals: Int, drafts: Int) {
            self.arrivals = arrivals
            self.drafts = drafts
        }
    }
}

/// One shelf's page: its grid of tiles, and what each is.
@MainActor
final class ShelfPage {
    let shelf: LibraryShelf
    let flow = FlowBox(spacing: 12, minColumns: 1, maxColumns: 12)
    let content = Box(.vertical, spacing: 24)
    let scroller: ScrolledWindow
    /// The tiles' selection IDs, by position (nil: the Add a Game tile).
    private(set) var ids: [String?] = []

    init(_ shelf: LibraryShelf) {
        self.shelf = shelf
        flow.style("shelf")
        gtk_flow_box_set_selection_mode(cast(flow.widget), GTK_SELECTION_SINGLE)
        gtk_flow_box_set_activate_on_single_click(cast(flow.widget), 0)
        gtk_flow_box_set_row_spacing(cast(flow.widget), 20)
        flow.accessibleLabel(shelf.name)
        content.margin(top: 24, bottom: 32, start: 28, end: 28)
        scroller = ScrolledWindow(content, horizontal: GTK_POLICY_NEVER)
        scroller.expand()
    }

    func set(_ tiles: [(Widget, String?)]) {
        flow.removeAll()
        ids = []
        for (child, id) in tiles {
            flow.append(child)
            ids.append(id)
        }
    }

    var selectedID: String? {
        guard let list = gtk_flow_box_get_selected_children(cast(flow.widget)) else { return nil }
        defer { g_list_free(list) }
        guard let child = list.pointee.data else { return nil }
        let index = Int(gtk_flow_box_child_get_index(child.assumingMemoryBound(to: GtkFlowBoxChild.self)))
        return ids.indices.contains(index) ? ids[index] : nil
    }

    func id(of child: gpointer?) -> String?? {
        guard let child else { return nil }
        let index = Int(gtk_flow_box_child_get_index(child.assumingMemoryBound(to: GtkFlowBoxChild.self)))
        return ids.indices.contains(index) ? .some(ids[index]) : nil
    }

    /// Selects a tile (nil: none), without anything else following.
    func select(_ id: String?) {
        guard let id, let index = ids.firstIndex(of: id),
              let child = gtk_flow_box_get_child_at_index(cast(flow.widget), Int32(index)) else {
            gtk_flow_box_unselect_all(cast(flow.widget))
            return
        }
        gtk_flow_box_select_child(cast(flow.widget), child)
    }

    func child(for id: String) -> WidgetPointer? {
        guard let index = ids.firstIndex(of: id),
              let child = gtk_flow_box_get_child_at_index(cast(flow.widget), Int32(index)) else { return nil }
        return cast(child)
    }

    /// Puts the keyboard on the grid: the selected tile, or the first.
    func focus() {
        if let id = selectedID, let child = child(for: id) {
            gtk_widget_grab_focus(child)
        } else if let first = gtk_flow_box_get_child_at_index(cast(flow.widget), 0) {
            gtk_widget_grab_focus(cast(first))
        }
    }
}

/// The library window's workings.
@MainActor
final class BookshelfController {
    let window: Window
    private let classics = ClassicsLibrary.shared
    private let stack = ViewStack()
    private let split: Widget
    private let details = Bin()
    private let detailsToggle: ToggleButton
    private let windowTitle = WindowTitle(BookshelfWindow.title)
    private var pages: [LibraryShelf: ShelfPage] = [:]
    private(set) var shelf: LibraryShelf
    private var selection: String?
    /// The last press on a grid (a double click plays; a click shows the
    /// details), for telling clicks from keys.
    private var press: (count: Int32, time: Date) = (0, .distantPast)
    private var switching = false
    private var draftDialog: GameDetailsDialog?
    /// What the details panel's showing.
    private var shownDetails: String?

    init() {
        shelf = UserDefaults.standard.string(forKey: LibraryShelf.defaultsKey).flatMap(LibraryShelf.init(rawValue:)) ?? .classics
        window = Window(title: BookshelfWindow.title, width: 1200, height: 820)
        window.minimumSize(width: 360, height: 420)
        split = Widget(adw_overlay_split_view_new())
        detailsToggle = ToggleButton(icon: "sidebar-show-right-symbolic")
        BookshelfWindow.controller = self

        buildPages()
        buildWindow()
        followDrafts()
        window.keep(self)
        App.addStandardShortcuts(to: window)
        stack.visible = shelf.rawValue
        windowTitle.subtitle = shelf.name
        showDetails()
        MainLoop.after(0) { [self] in
            pages[shelf]?.focus()
            selfTest()
        }
    }

    // MARK: The window

    private func buildWindow() {
        // The shelves, and the details beside them.
        adw_overlay_split_view_set_content(cast(split.widget), stack.widget)
        let sidebar = ToolbarView(content: details)
        sidebar.style("library-details")
        adw_overlay_split_view_set_sidebar(cast(split.widget), sidebar.widget)
        adw_overlay_split_view_set_sidebar_position(cast(split.widget), GTK_PACK_END)
        adw_overlay_split_view_set_min_sidebar_width(cast(split.widget), LibraryDetailMetrics.width)
        adw_overlay_split_view_set_max_sidebar_width(cast(split.widget), LibraryDetailMetrics.width)
        adw_overlay_split_view_set_show_sidebar(cast(split.widget), 0)
        let splitView = split.widget
        detailsToggle.object.on("toggled") { [detailsToggle] in
            adw_overlay_split_view_set_show_sidebar(cast(splitView), detailsToggle.isOn ? 1 : 0)
        }
        split.object.onChange("show-sidebar") { [detailsToggle] in
            detailsToggle.isOn = adw_overlay_split_view_get_show_sidebar(cast(splitView)) != 0
        }

        // The header: the tabs, and what to do.
        let switcher = stack.switcher()
        let title = Stack(transition: GTK_STACK_TRANSITION_TYPE_NONE)
        title.add(switcher, name: "switcher").add(windowTitle, name: "title")
        title.visible = "switcher"
        let header = HeaderBar(title: title)
        let machine = Button(icon: "computer-symbolic") { MachineWindow.openNew() }
            .tooltip("Open a BBC Micro window, to use without a game from the shelf")
            .accessibleLabel("BBC Micro")
        let add = Button(icon: "list-add-symbolic") { ClassicsLibrary.shared.chooseFiles() }
            .tooltip("Add disc images and cover pictures: Classics MacBeeb recognises, or your own games")
            .accessibleLabel("Add Games…")
        detailsToggle.tooltip("Show or hide the details of the selected game").accessibleLabel("Details")
        let menu = MenuButton(icon: "open-menu-symbolic", menu: Menu {
            MenuSection {
                MenuItem("New BBC Micro Window", "app.new-window")
                MenuItem("Welcome to MacBeeb", "app.welcome")
            }
            MenuSection {
                MenuItem("Preferences", "app.preferences", accel: "<Control>comma")
                MenuItem("Keyboard Shortcuts", "app.shortcuts", accel: "<Control>question")
                MenuItem("About MacBeeb", "app.about")
            }
        })
        .tooltip("Main Menu")
        gtk_menu_button_set_primary(cast(menu.widget), 1)
        header.start(add).start(machine).end(menu).end(detailsToggle)

        // Narrow: the tabs at the bottom.
        let switcherBar = Widget(adw_view_switcher_bar_new())
        adw_view_switcher_bar_set_stack(cast(switcherBar.widget), cast(stack.widget))

        let toolbar = ToolbarView(content: split).top(header).bottom(switcherBar)
        toolbar.raisedTop()
        window.content = toolbar

        // (The last that applies is the one used.) Narrower, the details
        // lie over the shelf; narrower still, the tabs go to the bottom.
        let medium = LibraryBreakpoints.make("max-width: 900sp")
        LibraryBreakpoints.set(medium, split, "collapsed", true)
        LibraryBreakpoints.add(medium, to: window)
        let narrow = LibraryBreakpoints.make("max-width: 800sp")
        LibraryBreakpoints.set(narrow, title, "visible-child-name", "title")
        LibraryBreakpoints.set(narrow, switcherBar, "reveal", true)
        LibraryBreakpoints.set(narrow, split, "collapsed", true)
        LibraryBreakpoints.add(narrow, to: window)

        stack.onSwitch { [self] name in
            guard let shelf = LibraryShelf(rawValue: name), shelf != self.shelf else { return }
            switchedShelf(to: shelf)
        }

        // Classics go to the Classics; anything else becomes one of My Games.
        toolbar.add(DropTarget.files { urls, _, _ in
            let wanted = urls.filter { MyGames.isDiscName($0) || MyGames.isCoverName($0) }
            ClassicsLibrary.shared.addFiles(wanted)
            return !wanted.isEmpty
        })

        // Escape puts the details away.
        let keys = KeyController()
        keys.onPressed { [self] keyval, _, modifiers in
            guard keyval == UInt32(GDK_KEY_Escape), modifiers.rawValue & (GDK_SHIFT_MASK.rawValue | GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue) == 0,
                  isShowingDetails else { return false }
            setShowingDetails(false)
            pages[shelf]?.focus()
            return true
        }
        window.add(keys)
        // Back from the browser: the app's active (Downloads is looked at).
        window.onActiveChanged { active in
            if active { App.noteActive() }
        }
        window.onDestroy { [self] in
            draftDialog = nil
            if BookshelfWindow.controller === self { BookshelfWindow.controller = nil }
        }
    }

    // MARK: Shelves

    private func buildPages() {
        for shelf in LibraryShelf.allCases {
            let page = shelf == .myGames ? makeMyGamesPage() : makeArchivePage(shelf)
            pages[shelf] = page
            stack.add(page.scroller, name: shelf.rawValue, title: shelf.name, icon: shelf.icon)
            followGrid(page)
        }
    }

    private func entries(on shelf: LibraryShelf) -> [ShelfEntry] {
        switch shelf {
        case .classics: classics.catalogue.shelf
        case .authorsPicks: classics.catalogue.picksShelf
        case .myGames: []
        }
    }

    /// The number a game has on a shelf: its rank, or its place among the
    /// picks.
    private func number(of entry: ShelfEntry, on shelf: LibraryShelf) -> Int? {
        guard case .game(let game) = entry else { return nil }
        return switch shelf {
        case .classics: game.rank
        case .authorsPicks: classics.catalogue.authorsPicks.firstIndex(of: game.id).map { $0 + 1 }
        case .myGames: nil
        }
    }

    private func makeArchivePage(_ shelf: LibraryShelf) -> ShelfPage {
        let page = ShelfPage(shelf)
        page.set(entries(on: shelf).map { entry in
            (ShelfTile(entry: entry, number: number(of: entry, on: shelf)).child, entry.id)
        })
        let header = Box(.vertical, spacing: 4) {
            Label(shelf.name, style: "title-1").wrap()
            Label(shelf == .authorsPicks
                  ? "Twenty favourites of MacBeeb’s author, from BBCMicro.co.uk."
                  : "Twenty favourites from BBCMicro.co.uk, ready to discover and play.",
                  style: "dim-label", "library-subtitle").wrap()
        }
        header.style("library-header")
        let banners = Box(.vertical, spacing: 12)
        followBanners(banners)
        let credit = Box(.vertical, spacing: 6) {
            Separator().margin(bottom: 6)
            Label("Game selection and preservation links courtesy of BBCMicro.co.uk. The BBC Micro Games Archive and its contributors have spent years restoring these games for modern and original hardware. MacBeeb is an independent emulator and is not affiliated with the archive.",
                  style: "dim-label", "library-credit").wrap()
            LinkButton("About the BBC Micro Games Archive", url: classics.catalogue.archive.aboutURL)
                .align(horizontal: GTK_ALIGN_START).style("library-link")
        }
        credit.margin(top: 8)
        page.content.append(header)
        page.content.append(banners)
        page.content.append(page.flow)
        page.content.append(credit)
        return page
    }

    private func makeMyGamesPage() -> ShelfPage {
        let page = ShelfPage(.myGames)
        let header = Box(.horizontal, spacing: 12) {
            Box(.vertical, spacing: 4) {
                Label("My Games", style: "title-1").wrap()
                Label("Drag in disc images and cover pictures, in either order or together.",
                      style: "dim-label", "library-subtitle").wrap()
            }
            .expand(horizontal: true)
            Button("_Add Games…") { ClassicsLibrary.shared.chooseFiles() }
                .align(vertical: GTK_ALIGN_CENTER)
                .tooltip("Add disc images and cover pictures: Classics MacBeeb recognises, or your own games")
        }
        header.style("library-header")
        page.content.append(header)
        page.content.append(page.flow)
        // The user's own games, and a book to add more.
        page.flow.libraryTrack({ ClassicsLibrary.shared.personalGames }) { [self] games in
            let selected = shelf == .myGames ? selection : nil
            switching = true
            page.set(games.map { (PersonalTile(game: $0).child, Self.myID($0)) } + [(AddGameTile().child, nil)])
            if let selected, page.ids.contains(selected) {
                page.select(selected)
            }
            switching = false
            if let selected, !page.ids.contains(selected), shelf == .myGames {
                selection = nil
                showDetails()
            }
        }
        return page
    }

    /// My Games' selection IDs.
    private static func myID(_ game: PersonalGame) -> String { "my-\(game.id.uuidString)" }

    // MARK: Notices

    private struct Notices: Equatable {
        var unresolved: [String]
        var waiting: [String]
        var watchState: ClassicsLibrary.WatchState
        var anyPending: Bool
        var autoDetect: Bool?
    }

    /// Downloads to identify, and whether downloads are looked for.
    private func followBanners(_ banners: Box) {
        let classics = classics
        banners.libraryTrack({
            Notices(unresolved: classics.unresolved.map { $0.digest + $0.fileName },
                    waiting: classics.pending.keys.sorted(), watchState: classics.watchState,
                    anyPending: !classics.pending.isEmpty, autoDetect: classics.autoDetect)
        }) { [self] notices in
            banners.removeAll()
            for candidate in classics.unresolved {
                banners.append(unresolvedBanner(candidate))
            }
            if case .noAccess = notices.watchState {
                banners.append(Self.banner(icon: "dialog-warning-symbolic",
                                           "MacBeeb can’t look in \(classics.downloadFolder.lastPathComponent) for downloaded games. Check that the folder is there and that you can read it, or choose another folder in Preferences. You can always add discs with Add Games… or by dragging them here.") {
                    Button("_Preferences…") { PreferencesWindow.show(page: .games) }
                })
            } else if notices.anyPending && notices.autoDetect != true {
                banners.append(Self.banner(icon: "folder-download-symbolic",
                                           "To add games automatically, allow MacBeeb to look for downloaded disk images. You can always import manually.") {
                    Button("_Look for Downloads") { ClassicsLibrary.shared.autoDetect = true }.style("suggested-action")
                })
            }
            banners.isVisible = gtk_widget_get_first_child(banners.widget) != nil
        }
    }

    /// A notice across the top of the shelf, with actions.
    private static func banner(icon: String, _ message: String, @WidgetList actions: () -> [Widget]) -> Widget {
        let buttons = Box(.horizontal, spacing: 6, actions)
        buttons.align(horizontal: GTK_ALIGN_END, vertical: GTK_ALIGN_CENTER)
        let row = Box(.horizontal, spacing: 14) {
            Icon(icon, size: 24).style("dim-label").align(vertical: GTK_ALIGN_CENTER)
            Label(message).wrap().expand(horizontal: true).align(vertical: GTK_ALIGN_CENTER)
            buttons
        }
        row.margin(14)
        return Bin(row).style("card")
    }

    private func unresolvedBanner(_ candidate: DiskCandidate) -> Widget {
        let classics = classics
        let waiting = classics.catalogue.allGames.filter { classics.pending[$0.id] != nil }
        let others = classics.catalogue.allGames.filter { classics.pending[$0.id] == nil }
        let choose = MenuButton(label: "Choose the Game")
        let banner = Self.banner(icon: "dialog-question-symbolic",
                                 "Downloaded disc found: “\(candidate.fileName)”. MacBeeb doesn’t recognise it. Which game is it?") {
            choose
            Button("Add to My Games…") { classics.addToMyGames(candidate) }
            Button("Ignore") { classics.dismiss(candidate) }.style("flat")
        }
        let actions = LibraryActions(on: choose, prefix: "disc")
        let waitingItems = waiting.enumerated().map { index, game in
            MenuItem(game.title, actions.add("waiting-\(index)") { classics.resolve(candidate, as: game) })
        }
        let otherItems = others.enumerated().map { index, game in
            MenuItem(game.title, actions.add("game-\(index)") { classics.resolve(candidate, as: game) })
        }
        choose.menu = Menu(entries: [MenuEntry.section(label: nil, entries: waitingItems),
                                     MenuEntry.section(label: nil, entries: otherItems)])
        return banner
    }

    // MARK: Selection and keys

    private func followGrid(_ page: ShelfPage) {
        // Presses, seen before the grid's own (which selects, or on a
        // double click activates).
        let presses = ClickGesture(button: 1)
        presses.phase(GTK_PHASE_CAPTURE)
        presses.onPressed { [self] count, _, _ in press = (count, Date()) }
        page.flow.add(presses)
        page.flow.object.on("selected-children-changed") { [self] in
            guard !switching, page.shelf == shelf else { return }
            let id = page.selectedID
            let clicked = Date().timeIntervalSince(press.time) < 0.5
            selection = id
            showDetails()
            // A click shows the details; arrow keys just move.
            if clicked && id != nil { setShowingDetails(true) }
        }
        page.flow.object.onPointer("child-activated") { [self] child in
            guard let id = page.id(of: child) else { return }
            let doubleClick = press.count >= 2 && Date().timeIntervalSince(press.time) < 0.5
            press = (0, .distantPast)
            guard let id else {
                // The Add a Game tile.
                if !doubleClick { classics.chooseFiles() }
                return
            }
            if doubleClick {
                playIfInstalled(id)
            } else {
                primaryAction(for: id)
            }
        }
    }

    private func switchedShelf(to shelf: LibraryShelf) {
        self.shelf = shelf
        UserDefaults.standard.set(shelf.rawValue, forKey: LibraryShelf.defaultsKey)
        windowTitle.subtitle = shelf.name
        switching = true
        for page in pages.values { page.select(nil) }
        switching = false
        selection = nil
        showDetails()
        setShowingDetails(false)
        pages[shelf]?.focus()
    }

    /// Shows a shelf (a disc or picture's to be one of My Games, say).
    func showShelf(_ shelf: LibraryShelf) {
        stack.visible = shelf.rawValue
    }

    private var isShowingDetails: Bool {
        adw_overlay_split_view_get_show_sidebar(cast(split.widget)) != 0
    }

    private func setShowingDetails(_ on: Bool) {
        // (Not before it's been laid out: libadwaita's slide goes awry.)
        guard split.width > 0 else {
            MainLoop.after(0.05) { [self] in setShowingDetails(on) }
            return
        }
        adw_overlay_split_view_set_show_sidebar(cast(split.widget), on ? 1 : 0)
    }

    /// The details panel, for what's selected (each follows its game as
    /// it changes).
    private func showDetails() {
        guard selection != shownDetails || details.child == nil else { return }
        shownDetails = selection
        guard let id = selection else {
            details.child = LibraryDetails.empty()
            return
        }
        if let game = personalGame(id) {
            details.child = PersonalDetailPanel.make(id: game.id)
        } else if let entry = entries(on: shelf).first(where: { $0.id == id }) {
            switch entry {
            case .game(let game): details.child = GameDetailPanel.make(game)
            case .archive(let book): details.child = ArchiveDetailPanel.make(book)
            }
        } else {
            details.child = LibraryDetails.empty()
        }
    }

    private func personalGame(_ id: String) -> PersonalGame? {
        classics.personalGames.first { Self.myID($0) == id }
    }

    /// Return on a tile: its main action.
    private func primaryAction(for id: String) {
        setShowingDetails(true)
        if let game = personalGame(id) {
            if game.discFile != nil { LibraryPlayer.play(game) }
            return
        }
        guard let entry = entries(on: shelf).first(where: { $0.id == id }) else { return }
        switch entry {
        case .archive(let book):
            Platform.open(book.url)
        case .game(let game):
            switch classics.state(of: game) {
            case .notInstalled: classics.get(game)
            case .installed(let record): LibraryPlayer.play(game, record: record)
            default: break
            }
        }
    }

    /// A double click on a tile: play it if it's been downloaded. (Return
    /// also gets it, but a double click shouldn't start a download.)
    private func playIfInstalled(_ id: String) {
        if let game = personalGame(id) {
            if game.discFile != nil { LibraryPlayer.play(game) }
            return
        }
        guard case .game(let game)? = entries(on: shelf).first(where: { $0.id == id }),
              case .installed(let record) = classics.state(of: game) else { return }
        LibraryPlayer.play(game, record: record)
    }

    // MARK: Adding and editing My Games

    /// The first game waiting for its details, in a dialog over the
    /// library; the next when it's done.
    private func followDrafts() {
        let classics = classics
        window.libraryTrack({ classics.drafts.first?.id }) { [self] id in
            if let dialog = draftDialog, dialog.draft.id != id {
                draftDialog = nil
                dialog.close()
            }
            guard draftDialog == nil, let draft = classics.drafts.first else { return }
            draftDialog = GameDetailsDialog(draft: draft)
            draftDialog?.present(over: window)
        }
    }

    // MARK: Self-tests

    /// With `-MacBeebSelfTest` (and `-MacBeebSelfTestOpen app.library`),
    /// the library in a given state, to capture:
    ///
    /// - `-MacBeebLibraryTab classics|authorsPicks|myGames`: the tab.
    /// - `-MacBeebLibraryWidth N`, `-MacBeebLibraryHeight N`: its size.
    /// - `-MacBeebLibrarySelect ID` (after `-MacBeebLibrarySelectDelay`
    ///   seconds): a tile selected, with its details (`first-mine`: the
    ///   first of My Games).
    /// - `-MacBeebLibraryActivate ID,ID…`: Return on each in turn.
    /// - `-MacBeebLibraryMenu ID`: a tile's context menu, its Edit… chosen.
    /// - `-MacBeebLibraryScrollToEnd <true/>`: the shelf scrolled down.
    /// - `-MacBeebLibraryAdd PATH,PATH…`: discs and pictures added (the
    ///   details dialog); `-MacBeebLibraryEdit N`: the Nth of My Games
    ///   edited; `-MacBeebLibrarySaveDraft <true/>`: Add Game pressed;
    ///   `-MacBeebLibraryDialogHeight N`: the dialog taller.
    private func selfTest() {
        guard LaunchScreen.isSelfTest else { return }
        let defaults = UserDefaults.standard
        let firstMine = classics.personalGames.first.map(Self.myID) ?? ""
        func id(_ name: some StringProtocol) -> String { name == "first-mine" ? firstMine : String(name) }

        let width = defaults.integer(forKey: "MacBeebLibraryWidth")
        if width > 0 {
            window.setDefaultSize(width: Int32(width), height: Int32(max(defaults.integer(forKey: "MacBeebLibraryHeight"), 820)))
        }
        if let name = defaults.string(forKey: "MacBeebLibrarySelect") {
            MainLoop.after(defaults.double(forKey: "MacBeebLibrarySelectDelay")) { [self] in
                selection = id(name)
                pages[shelf]?.select(selection)
                showDetails()
                setShowingDetails(true)
            }
        }
        for (index, name) in (defaults.string(forKey: "MacBeebLibraryActivate") ?? "").split(separator: ",").enumerated() {
            MainLoop.after(1 + Double(index) * 2.5) { [self] in
                selection = id(name)
                pages[shelf]?.select(selection)
                showDetails()
                primaryAction(for: id(name))
            }
        }
        if let name = defaults.string(forKey: "MacBeebLibraryMenu") {
            MainLoop.after(1) { [self] in
                guard let child = pages[shelf]?.child(for: id(name)),
                      let popover = Widget(child).openLibraryContextMenu() else { return }
                MainLoop.after(1) {
                    // (Popovers aren't captured: its action shows it worked.)
                    gtk_widget_activate_action_variant(popover.widget, "game.edit", nil)
                    popover.dismiss()
                }
            }
        }
        if defaults.bool(forKey: "MacBeebLibraryScrollToEnd") {
            MainLoop.after(2) { [self] in pages[shelf]?.scroller.scrollToEnd() }
        }
        let edit = defaults.integer(forKey: "MacBeebLibraryEdit")
        if edit > 0, classics.personalGames.count >= edit {
            classics.edit(classics.personalGames[edit - 1])
        }
        if let paths = defaults.string(forKey: "MacBeebLibraryAdd") {
            classics.addFiles(paths.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
        }
        if defaults.bool(forKey: "MacBeebLibrarySaveDraft") {
            MainLoop.after(2) { [self] in
                if let dialog = draftDialog { gtk_widget_activate(dialog.saveButtonWidget.widget) }
            }
        }
    }
}
