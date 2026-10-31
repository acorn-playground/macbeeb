import AppKit
import BeebLibrary
import SwiftUI

/// The shelves of the game library, one to a tab.
enum ShelfTab: String, CaseIterable, Identifiable {
    /// BBCMicro.co.uk's top 20.
    case classics
    /// MacBeeb's author's favourites, also from BBCMicro.co.uk.
    case authorsPicks
    /// The user's own.
    case myGames

    var id: Self { self }

    var name: String {
        switch self {
        case .classics: "BBC Micro Classics"
        case .authorsPicks: "Author’s Picks"
        case .myGames: "My Games"
        }
    }
}

/// The game library: the BBC Micro Classics (BBCMicro.co.uk's top 20 games
/// and a book for the archive itself), the Author's Picks and My Games, in
/// tabs. Games from the archive are downloaded from its pages in the user's
/// browser; MacBeeb never downloads them itself. A game on both archive
/// shelves is the same game, installed once.
struct BookshelfView: View {
    static let windowID = "bookshelf"
    static let title = "Game Library"

    @State private var classics = ClassicsLibrary.shared
    @AppStorage("MacBeebLibraryTab") private var tab = ShelfTab.classics
    @State private var selection: String?
    @State private var showingDetail = false
    @State private var columns = 4
    @FocusState private var gridFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let tileWidth: CGFloat = 168
    private static let detailWidth: CGFloat = 320
    private static let spacing: CGFloat = 28
    /// The column count kept while the details panel slides in or out, so
    /// the tiles move to their new rows once, after it, not on every frame.
    @State private var heldColumns: Int?
    @State private var release: Task<Void, Never>?
    @State private var gridWidth: CGFloat = 0
    private var grid: ShelfLayout {
        ShelfLayout(tileWidth: Self.tileWidth, spacing: Self.spacing, heldColumns: heldColumns)
    }
    /// My Games' selection IDs.
    private static func myID(_ game: PersonalGame) -> String { "my-\(game.id.uuidString)" }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Group {
                        switch tab {
                        case .classics, .authorsPicks:
                            header
                            banners
                        case .myGames:
                            myGamesHeader
                        }
                    }
                    Group {
                        switch tab {
                        case .classics, .authorsPicks: shelfGrid
                        case .myGames: myGamesGrid
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        gridWidth = width
                        columns = ShelfLayout.columns(in: width, tileWidth: Self.tileWidth, spacing: Self.spacing)
                    }
                    // Tiles slide to their new rows when the column count changes.
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: columns)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($gridFocused)
                    .onMoveCommand { direction in
                        move(direction)
                        if let selection { withAnimation(reduceMotion ? nil : .default) { scroller.scrollTo(selection) } }
                    }
                    .onKeyPress(.return) {
                        guard let selection else { return .ignored }
                        primaryAction(for: selection)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard showingDetail else { return .ignored }
                        showingDetail = false
                        return .handled
                    }
                    if tab != .myGames {
                        credit
                    }
                }
                .padding(24)
            }
        }
        .background(.background)
        .inspector(isPresented: $showingDetail) {
            Group {
                if let selection, let entry = shelf.first(where: { $0.id == selection }) {
                    switch entry {
                    case .game(let game): GameDetail(game: game, openMachine: openMachine)
                    case .archive(let book): ArchiveDetail(book: book)
                    }
                } else if let game = selectedPersonalGame {
                    PersonalGameDetail(game: game, openMachine: openMachine)
                }
            }
            // A fixed width, so the grid knows where it'll end up.
            .inspectorColumnWidth(Self.detailWidth)
        }
        // Classics go to the Classics; anything else becomes one of My Games.
        .dropDestination(for: URL.self) { urls, _ in
            let wanted = urls.filter { MyGames.isDiscName($0) || MyGames.isCoverName($0) }
            classics.addFiles(wanted)
            return !wanted.isEmpty
        }
        .sheet(item: Binding(get: { classics.drafts.first },
                             set: { if $0 == nil, let draft = classics.drafts.first { classics.cancel(draft) } })) { draft in
            GameDetailsSheet(draft: draft)
        }
        .navigationTitle(Self.title)
        .navigationSubtitle(tab.name)
        // The panel's about to slide in or out: move the tiles straight to
        // the columns there'll be room for, alongside it, and keep them there
        // until it's done. Until then the panel covers any that don't fit yet.
        .onChange(of: showingDetail) { _, showing in
            let width = gridWidth + (showing ? -Self.detailWidth : Self.detailWidth)
            let target = ShelfLayout.columns(in: width, tileWidth: Self.tileWidth, spacing: Self.spacing)
            release?.cancel()
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { heldColumns = target }
            release = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { heldColumns = nil }
            }
        }
        .onChange(of: tab) {
            selection = nil
            showingDetail = false
            gridFocused = true
        }
        // A disc or picture that's to be one of My Games: show them.
        .onChange(of: classics.drafts.count) { old, new in
            if new > old { tab = .myGames }
        }
        // A download arriving brings the library to the front (when no
        // machine window is open, it's the one watching).
        .bringsLibraryForwardOnArrival()
        .onAppear {
            gridFocused = true
            // When it's the only window at launch, it's the one that says
            // what's new.
            if LaunchScreen.atLaunch == .games && WhatsNew.shouldShowOnLaunch() {
                openWindow(id: WhatsNewView.windowID)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Shelf", selection: $tab) {
                    ForEach(ShelfTab.allCases) { tab in
                        Text(tab.name).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Choose a shelf")
            }
            ToolbarItem {
                Button {
                    openMachine()
                } label: {
                    Label("BBC Micro", systemImage: "desktopcomputer")
                }
                .help("Open a BBC Micro window, to use without a game from the shelf")
            }
            ToolbarItem {
                Button {
                    classics.chooseFiles()
                } label: {
                    Label("Add Games…", systemImage: "plus")
                }
                .help("Add disc images and cover pictures: Classics MacBeeb recognises, or your own games")
            }
            ToolbarItem {
                Button {
                    showingDetail.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.right")
                }
                .help("Show or hide the details of the selected game")
            }
        }
    }

    /// The current archive tab's books, in order.
    private var shelf: [ShelfEntry] {
        switch tab {
        case .classics: classics.catalogue.shelf
        case .authorsPicks: classics.catalogue.picksShelf
        case .myGames: []
        }
    }

    /// The number a game has on the current shelf: its rank, or its place
    /// among the picks.
    private func number(of entry: ShelfEntry) -> Int? {
        guard case .game(let game) = entry else { return nil }
        return switch tab {
        case .classics: game.rank
        case .authorsPicks: classics.catalogue.authorsPicks.firstIndex(of: game.id).map { $0 + 1 }
        case .myGames: nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tab.name)
                .font(.largeTitle.weight(.semibold))
            Text(tab == .authorsPicks
                 ? "Twenty favourites of MacBeeb’s author, from BBCMicro.co.uk."
                 : "Twenty favourites from BBCMicro.co.uk, ready to discover and play.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var banners: some View {
        ForEach(classics.unresolved, id: \.digest) { candidate in
            Banner(systemImage: "questionmark.square.dashed") {
                Text("Downloaded disc found: “\(candidate.fileName)”. MacBeeb doesn’t recognise it. Which game is it?")
            } actions: {
                Menu("Choose the Game") {
                    let waiting = classics.catalogue.allGames.filter { classics.pending[$0.id] != nil }
                    ForEach(waiting) { game in
                        Button(game.title) { classics.resolve(candidate, as: game) }
                    }
                    if !waiting.isEmpty { Divider() }
                    ForEach(classics.catalogue.allGames.filter { classics.pending[$0.id] == nil }) { game in
                        Button(game.title) { classics.resolve(candidate, as: game) }
                    }
                }
                .fixedSize()
                Button("Add to My Games…") { classics.addToMyGames(candidate) }
                Button("Ignore") { classics.dismiss(candidate) }
            }
        }
        if case .noAccess = classics.watchState {
            Banner(systemImage: "folder.badge.questionmark") {
                Text("MacBeeb can’t look in \(classics.downloadFolder.lastPathComponent) for downloaded games. Allow it in System Settings ▸ Privacy & Security ▸ Files & Folders, or choose another folder in Settings. You can always add discs with Add Games… or by dragging them here.")
            } actions: {
                SettingsLink { Text("Settings…") }
            }
        } else if !classics.pending.isEmpty && classics.autoDetect != true {
            Banner(systemImage: "arrow.down.circle") {
                Text("To add games automatically, allow MacBeeb to look for downloaded disk images. You can always import manually.")
            } actions: {
                Button("Look for Downloads") { classics.autoDetect = true }
            }
        }
    }

    private var shelfGrid: some View {
        grid {
            ForEach(shelf) { entry in
                ShelfTile(entry: entry, number: number(of: entry), selected: selection == entry.id)
                    .id(entry.id)
                    .onTapGesture {
                        select(entry.id)
                        gridFocused = true
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { playIfInstalled(entry) })
                    .accessibilityAction { select(entry.id) }
            }
        }
    }

    private var myGamesHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("My Games")
                    .font(.largeTitle.weight(.semibold))
                Text("Drag in disc images and cover pictures, in either order or together.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Add Games…") { classics.chooseFiles() }
        }
    }

    /// The user's own games, and a book to add more.
    private var myGamesGrid: some View {
        grid {
            ForEach(classics.personalGames) { game in
                PersonalTile(game: game, selected: selection == Self.myID(game))
                    .id(Self.myID(game))
                    .onTapGesture {
                        select(Self.myID(game))
                        gridFocused = true
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        if game.discFile != nil { Player.play(game, openMachine: openMachine) }
                    })
                    .accessibilityAction { select(Self.myID(game)) }
                    .contextMenu {
                        Button("Edit…") { classics.edit(game) }
                        Button(game.discFile == nil ? "Choose Disc…" : "Replace Disc…") { classics.chooseDisc(for: game) }
                        Button(game.coverFile == nil ? "Add Cover…" : "Change Cover…") { classics.chooseCover(for: game) }
                        Divider()
                        Button("Remove…") { classics.remove(game) }
                    }
            }
            AddGameTile()
        }
    }

    private var selectedPersonalGame: PersonalGame? {
        classics.personalGames.first { Self.myID($0) == selection }
    }

    private var credit: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Game selection and preservation links courtesy of BBCMicro.co.uk. The BBC Micro Games Archive and its contributors have spent years restoring these games for modern and original hardware. MacBeeb is an independent emulator and is not affiliated with the archive.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("About the BBC Micro Games Archive", destination: classics.catalogue.archive.aboutURL)
                .font(.callout)
        }
        .padding(.top, 8)
    }

    // MARK: Selection and keys

    private func select(_ id: String) {
        selection = id
        showingDetail = true
    }

    private func move(_ direction: MoveCommandDirection) {
        let ids = switch tab {
        case .classics, .authorsPicks: shelf.map(\.id)
        case .myGames: classics.personalGames.map(Self.myID)
        }
        guard !ids.isEmpty else { return }
        let current = selection.flatMap(ids.firstIndex(of:))
        let step = switch direction {
        case .left: -1
        case .right: 1
        case .up: -columns
        case .down: columns
        @unknown default: 0
        }
        let next = current.map { min(max($0 + step, 0), ids.count - 1) } ?? 0
        selection = ids[next]
    }

    /// Return on a tile: its main action.
    private func primaryAction(for id: String) {
        if let game = selectedPersonalGame, Self.myID(game) == id {
            showingDetail = true
            if game.discFile != nil { Player.play(game, openMachine: openMachine) }
            return
        }
        guard let entry = shelf.first(where: { $0.id == id }) else { return }
        showingDetail = true
        switch entry {
        case .archive(let book):
            NSWorkspace.shared.open(book.url)
        case .game(let game):
            switch classics.state(of: game) {
            case .notInstalled: classics.get(game)
            case .installed(let record): Player.play(game, record: record, openMachine: openMachine)
            default: break
            }
        }
    }

    /// Double click on a tile: play it if it's been downloaded. (Return
    /// also gets it, but a double click shouldn't start a download.)
    private func playIfInstalled(_ entry: ShelfEntry) {
        guard case .game(let game) = entry, case .installed(let record) = classics.state(of: game) else { return }
        Player.play(game, record: record, openMachine: openMachine)
    }

    private func openMachine() {
        openWindow(id: MachineWindow.windowID)
    }
}

/// The shelf's grid: as many columns of same-sized tiles as fit, from the
/// left, each row's tiles sitting on its bottom. Unlike a LazyVGrid, it
/// animates a change in the number of columns by moving each tile to its
/// new place, rather than rebuilding the rows.
private struct ShelfLayout: Layout {
    let tileWidth: CGFloat
    let spacing: CGFloat
    /// Columns to use whatever the width; the rest are hidden for the while.
    var heldColumns: Int?

    static func columns(in width: CGFloat, tileWidth: CGFloat, spacing: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, Int((width + spacing) / (tileWidth + spacing)))
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(range: Range<Int>, height: CGFloat)] {
        let columns = heldColumns ?? Self.columns(in: width, tileWidth: tileWidth, spacing: spacing)
        let proposal = ProposedViewSize(width: tileWidth, height: nil)
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            let range = start..<min(start + columns, subviews.count)
            return (range, range.map { subviews[$0].sizeThatFits(proposal).height }.max() ?? 0)
        }
    }

    private func height(of rows: [(range: Range<Int>, height: CGFloat)]) -> CGFloat {
        rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // SwiftUI asks with nil, zero and infinite widths to find the
        // window's ideal, minimum and maximum sizes: one column, at least.
        switch proposal.width {
        case let width? where width.isFinite:
            let width = max(width, tileWidth)
            return CGSize(width: width, height: height(of: rows(width, subviews)))
        case nil:
            let width = (tileWidth + spacing) * 4 - spacing
            return CGSize(width: width, height: height(of: rows(width, subviews)))
        default:
            // As wide as it's given, in one row.
            let width = (tileWidth + spacing) * CGFloat(max(subviews.count, 1))
            return CGSize(width: .infinity, height: height(of: rows(width, subviews)))
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let proposal = ProposedViewSize(width: tileWidth, height: nil)
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            for (column, index) in row.range.enumerated() {
                let x = bounds.minX + CGFloat(column) * (tileWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y + row.height), anchor: .bottomLeading, proposal: proposal)
            }
            y += row.height + spacing
        }
    }
}

/// One book on the shelf: a game's cover, or the archive's.
private struct ShelfTile: View {
    let entry: ShelfEntry
    /// Its rank or place on this shelf.
    let number: Int?
    let selected: Bool
    @State private var classics = ClassicsLibrary.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let coverHeight: CGFloat = 210

    var body: some View {
        VStack(spacing: 8) {
            // Nothing drawn over the artwork: the rank and state go below.
            cover
                .frame(height: Self.coverHeight, alignment: .bottom)
                .frame(maxWidth: .infinity)
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    if let number {
                        Text("\(number)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.headline)
                }
                .lineLimit(1)
                status
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(selected ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            if case .game(let game) = entry, classics.state(of: game) == .notInstalled {
                Button("Get from BBCMicro.co.uk") { classics.get(game) }
            }
            if case .game(let game) = entry, let latest = classics.latestSnapshot(of: game) {
                Button("Resume") {
                    Player.restore(latest, title: game.title) { openWindow(id: MachineWindow.windowID) }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.4), value: statusText)
    }

    /// Ready, or a Get button, or what's happening.
    @ViewBuilder private var status: some View {
        if case .game(let game) = entry {
            if classics.justInstalled == game.id {
                Label("Added to your library", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                switch classics.state(of: game) {
                case .notInstalled:
                    Button {
                        classics.get(game)
                    } label: {
                        Label("Get", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.link)
                    .help("Get \(game.title) from its BBCMicro.co.uk page")
                case .waiting:
                    Label("Waiting for download…", systemImage: "clock")
                        .foregroundStyle(.orange)
                case .importing:
                    Label("Importing…", systemImage: "arrow.down.doc")
                        .foregroundStyle(.orange)
                case .installed:
                    if let latest = classics.latestSnapshot(of: game) {
                        ResumeLink(snapshot: latest, title: game.title)
                    } else {
                        Label("Ready to play", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                case .hardwareUnavailable:
                    Label("Needs other hardware", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Explore the archive ↗")
                .foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder private var cover: some View {
        switch entry {
        case .game(let game):
            CoverImage(game: game)
                // Not installed yet: a touch darker, still in full colour.
                .brightness(isInstalled ? 0 : -0.06)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
                .scaleEffect(classics.justInstalled == game.id && !reduceMotion ? 1.04 : 1)
        case .archive(let book):
            ArchiveCover(book: book)
                .aspectRatio(0.7, contentMode: .fit)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
        }
    }

    private var title: String {
        switch entry {
        case .game(let game): game.title
        case .archive: "BBCMicro.co.uk"
        }
    }

    private var isInstalled: Bool {
        guard case .game(let game) = entry else { return true }
        return classics.installed[game.id] != nil
    }

    private var statusText: String {
        guard case .game(let game) = entry else { return "Explore the archive ↗" }
        if classics.justInstalled == game.id { return "Added to your library" }
        return switch classics.state(of: game) {
        case .notInstalled: "Get from BBCMicro.co.uk"
        case .waiting: "Waiting for download…"
        case .importing: "Importing…"
        case .installed: classics.latestSnapshot(of: game) == nil ? "Ready to play" : "Ready to resume"
        case .hardwareUnavailable: "Needs other hardware"
        }
    }

    private var helpText: String {
        switch entry {
        case .game(let game):
            (number.map { "#\($0) " } ?? "") + game.title + (game.editionLabel.map { " (\($0))" } ?? "") + " — \(statusText)"
        case .archive(let book):
            book.pitch
        }
    }

    private var accessibilityLabel: String {
        switch entry {
        case .game(let game): (number.map { "Number \($0), " } ?? "") + "\(game.title). \(statusText)."
        case .archive(let book): "\(book.title), BBCMicro.co.uk. \(book.subtitle)."
        }
    }
}

/// A game's bundled cover at its own proportions, or a typographic stand-in.
struct CoverImage: View {
    let game: CuratedGame

    var body: some View {
        if let image = CoverCache.image(for: game) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .coverPop()
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityHidden(true)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                VStack(spacing: 8) {
                    Text(game.title.uppercased())
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.yellow)
                    if let publisher = game.publisher {
                        Text(publisher)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(10)
            }
            .aspectRatio(0.7, contentMode: .fit)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Old box scans are faded and flat: a little more colour and contrast
    /// makes them stand out on the shelf.
    func coverPop() -> some View {
        saturation(1.2).contrast(1.1)
    }
}

@MainActor
enum CoverCache {
    private static var images: [String: NSImage] = [:]

    static func image(for game: CuratedGame) -> NSImage? {
        if let image = images[game.id] { return image }
        guard let url = BeebLibrary.coverURL(for: game), let image = NSImage(contentsOf: url) else { return nil }
        images[game.id] = image
        return image
    }
}

/// The archive's book: typographic, in the BBC Micro's colours, with no
/// third-party logo.
struct ArchiveCover: View {
    let book: ArchiveBook

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.13, blue: 0.11), Color(red: 0.08, green: 0.07, blue: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
            // The BBC Micro's red function keys, as a band.
            VStack(spacing: 3) {
                ForEach(0..<3) { _ in
                    Rectangle().fill(Color(red: 0.78, green: 0.12, blue: 0.12))
                        .frame(height: 4)
                }
            }
            .padding(.top, 22)
            VStack(alignment: .leading, spacing: 6) {
                Spacer()
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.3))
                Text("The BBC Micro Archive")
                    .font(.system(.title3, design: .serif).weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("BBCMicro.co.uk")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.3))
                Text("Thousands more games")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(12)
        }
        .accessibilityHidden(true)
    }
}

/// A notice across the top of the shelf, with actions.
private struct Banner<Message: View, Actions: View>: View {
    let systemImage: String
    @ViewBuilder let message: Message
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            message
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Details

private struct GameDetail: View {
    let game: CuratedGame
    let openMachine: () -> Void
    @State private var classics = ClassicsLibrary.shared
    @State private var snapshots: [SnapshotManifest] = []
    @State private var modified = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CoverImage(game: game)
                    .frame(maxHeight: 260)
                    .frame(maxWidth: .infinity)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.title2.weight(.semibold))
                    if let edition = game.editionLabel {
                        Text(edition)
                            .foregroundStyle(.secondary)
                    }
                    Group {
                        if let rank = game.rank {
                            Text("#\(rank) in BBCMicro.co.uk’s top 20")
                        }
                        if let pick = classics.catalogue.authorsPicks.firstIndex(of: game.id) {
                            Text("#\(pick + 1) of the Author’s Picks")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                actions

                Text(game.description)
                    .fixedSize(horizontal: false, vertical: true)

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    if let publisher = game.publisher {
                        GridRow {
                            Text("Publisher").foregroundStyle(.secondary)
                            Text(publisher + (game.year.map { ", \($0)" } ?? ""))
                        }
                    }
                    if let authors = game.authors {
                        GridRow {
                            Text("By").foregroundStyle(.secondary)
                            Text(authors)
                        }
                    }
                    GridRow {
                        Text("Plays on").foregroundStyle(.secondary)
                        Text(game.machine.summary)
                    }
                }
                .font(.callout)

                Link("View on BBCMicro.co.uk ↗", destination: game.archivePageURL)
                    .font(.callout)

                if classics.installed[game.id] != nil || !snapshots.isEmpty {
                    SnapshotList(snapshots: snapshots, ownerTitle: game.title)
                }

                Text("Disc and preservation work by BBCMicro.co.uk and its contributors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .task(id: TaskKey(game: game.id, record: classics.installed[game.id]?.libraryID,
                          changes: classics.snapshotChanges)) {
            await load()
        }
    }

    private struct TaskKey: Equatable {
        var game: String
        var record: UUID?
        var changes: Int
    }

    private func load() async {
        guard let record = classics.installed[game.id] else {
            snapshots = []
            modified = false
            return
        }
        snapshots = await classics.snapshots.history(owner: record.libraryID)
        modified = await classics.library.workingCopyIsModified(record)
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch classics.state(of: game) {
            case .notInstalled:
                Button {
                    classics.get(game)
                } label: {
                    Text("Get from BBCMicro.co.uk ↗").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Import Disc…") { classics.chooseAndImport(as: game) }
                    .buttonStyle(.link)
            case .waiting:
                Text("Download the SSD from BBCMicro.co.uk. MacBeeb will add it automatically when it finishes.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if classics.autoDetect != true {
                    Text("Looking for downloads is off, so import the disc once it’s downloaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    NSWorkspace.shared.open(game.archivePageURL)
                } label: {
                    Text("Open Page Again ↗").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for download…").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Import Disc…") { classics.chooseAndImport(as: game) }
                    Button("Cancel Waiting") { classics.cancelWaiting(game) }
                }
                .buttonStyle(.link)
            case .importing:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Importing…").foregroundStyle(.secondary)
                }
            case .installed(let record):
                if classics.justInstalled == game.id {
                    Label("Added to your library", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button {
                    Player.play(game, record: record, openMachine: openMachine)
                } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                if let latest = snapshots.first {
                    ResumeButton(snapshot: latest, title: game.title, openMachine: openMachine)
                }
                if !record.verified {
                    Text("You chose this disc for \(game.title); MacBeeb didn’t recognise it as the BBCMicro.co.uk edition.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Reveal Disc") { classics.reveal(record) }
                    if modified {
                        Button("Revert Disc…") { revert(record) }
                            .help("Put the disc back as it was downloaded, undoing anything the game saved to it")
                    }
                    Button("Remove…") { classics.remove(game) }
                }
                .buttonStyle(.link)
            case .hardwareUnavailable(let record, let reason):
                Label("Requirements", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(reason + " It won’t be run on other hardware.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Reveal Disc") { classics.reveal(record) }
                    Button("Remove…") { classics.remove(game) }
                }
                .buttonStyle(.link)
            }
        }
    }

    private func revert(_ record: InstalledGame) {
        let alert = NSAlert()
        alert.messageText = "Revert \(game.title)’s disc?"
        alert.informativeText = "The disc goes back to how it was downloaded, losing anything the game saved to it. Quick saves aren’t affected. If the game is running, play it again afterwards."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await classics.library.revertWorkingCopy(record)
            } catch {
                NSAlert(error: error).runModal()
            }
            await load()
        }
    }
}

/// A disc's quick saves, newest first: their screenshots, each a button
/// that carries on from there.
struct SnapshotList: View {
    let snapshots: [SnapshotManifest]
    let ownerTitle: String
    @State private var classics = ClassicsLibrary.shared
    @Environment(\.openWindow) private var openWindow

    private static let columns = [GridItem(.flexible(), spacing: 10, alignment: .top),
                                  GridItem(.flexible(), spacing: 10, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Snapshots").font(.headline)
                Spacer()
                if !snapshots.isEmpty {
                    Button("Delete All…") { deleteAll() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            if snapshots.isEmpty {
                Text("While it’s playing, File ▸ Quick Save (⇧⌘F6) saves the game exactly as it is, and Quick Load (⇧⌘F5) goes back to it. The last five are kept. (On some keyboards, hold fn for F5 and F6.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Click one to carry on from there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                ForEach(snapshots) { snapshot in
                    SnapshotCard(snapshot: snapshot, title: nil) {
                        Player.restore(snapshot, title: ownerTitle) { openWindow(id: MachineWindow.windowID) }
                    }
                    .contextMenu {
                        Button("Resume from Here") {
                            Player.restore(snapshot, title: ownerTitle) { openWindow(id: MachineWindow.windowID) }
                        }
                        Divider()
                        Button("Delete Snapshot") { delete(snapshot) }
                    }
                }
            }
        }
    }

    private func delete(_ snapshot: SnapshotManifest) {
        Task {
            try? await classics.snapshots.delete(snapshot)
            changed(snapshot.owner)
        }
    }

    private func deleteAll() {
        guard let owner = snapshots.first?.owner else { return }
        let alert = NSAlert()
        alert.messageText = "Delete all of \(ownerTitle)’s snapshots?"
        alert.informativeText = "This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            try? await classics.snapshots.deleteAll(owner: owner)
            changed(owner)
        }
    }

    private func changed(_ owner: UUID) {
        classics.noteSnapshotsChanged()
        for machine in MachineController.all.values where machine.snapshotOwner?.id == owner {
            machine.refreshSnapshotHistory()
        }
    }
}

/// A snapshot as a button: its screenshot, when it was saved and, if
/// asked, whose it is.
struct SnapshotCard: View {
    let snapshot: SnapshotManifest
    let title: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                SnapshotThumbnail(snapshot: snapshot)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(hovering ? Color.accentColor : .secondary.opacity(0.3), lineWidth: hovering ? 2 : 1)
                    }
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.largeTitle)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                            .opacity(hovering ? 1 : 0)
                    }
                if let title {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Text(snapshot.created, format: Self.dateFormat)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Carry on from here")
        .accessibilityLabel((title.map { "\($0), " } ?? "") + "snapshot from \(snapshot.created.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityHint("Carries on from here")
    }

    /// "Thu 22 Oct, 14:32".
    static let dateFormat = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
}

/// A snapshot's screenshot, at the BBC's screen proportions.
struct SnapshotThumbnail: View {
    let snapshot: SnapshotManifest
    @State private var image: NSImage?

    var body: some View {
        Rectangle()
            .fill(.black)
            .aspectRatio(Renderer.aspect, contentMode: .fit)
            .overlay {
                if let image {
                    // Stretched to the box: the frame's pixels aren't square.
                    Image(nsImage: image).resizable().interpolation(.medium)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: snapshot.id) {
                guard let url = await ClassicsLibrary.shared.snapshots.thumbnailURL(snapshot) else { return }
                image = await Task.detached { NSImage(contentsOf: url) }.value
            }
    }
}

/// A tile's status when there's a snapshot: a link that carries on from
/// the newest.
struct ResumeLink: View {
    let snapshot: SnapshotManifest
    let title: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            Player.restore(snapshot, title: title) { openWindow(id: MachineWindow.windowID) }
        } label: {
            Label("Resume", systemImage: "clock.arrow.circlepath")
        }
        .buttonStyle(.link)
        .help("Carry on from the snapshot saved \(snapshot.created.formatted(SnapshotCard.dateFormat))")
    }
}

/// The button under Play that carries on from the newest snapshot.
struct ResumeButton: View {
    let snapshot: SnapshotManifest
    let title: String
    let openMachine: () -> Void

    var body: some View {
        Button {
            Player.restore(snapshot, title: title, openMachine: openMachine)
        } label: {
            Label("Resume", systemImage: "clock.arrow.circlepath")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .help("Carry on from the snapshot saved \(snapshot.created.formatted(SnapshotCard.dateFormat))")
    }
}

private struct ArchiveDetail: View {
    let book: ArchiveBook

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ArchiveCover(book: book)
                    .aspectRatio(0.7, contentMode: .fit)
                    .frame(maxHeight: 260)
                    .frame(maxWidth: .infinity)
                Text(book.title)
                    .font(.title2.weight(.semibold))
                Text(book.pitch)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NSWorkspace.shared.open(book.url)
                } label: {
                    Text("Visit BBCMicro.co.uk ↗").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text(book.about)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Game selection and preservation links courtesy of BBCMicro.co.uk. MacBeeb is an independent emulator and is not affiliated with the archive.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("About the BBC Micro Games Archive ↗", destination: book.aboutURL)
            }
            .padding(16)
        }
    }
}

// MARK: Playing

/// Starts library games and restores snapshots in the machine in front
/// (or a new one), asking before taking over a machine that's busy.
@MainActor
enum Player {
    static func play(_ game: CuratedGame, record: InstalledGame, openMachine: @escaping () -> Void) {
        Task {
            let url: URL
            do {
                url = try await ClassicsLibrary.shared.library.prepareWorkingCopy(record)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
            let launch: (MachineController) -> Void = { $0.play(game, disc: url, record: record) }
            guard let machine = MachineController.frontmost else {
                MachineController.pendingLaunch = launch
                openMachine()
                return
            }
            if machine.isPlayingSomething && machine.snapshotOwner?.id != record.libraryID {
                guard confirm("Play \(game.title)?",
                              detail: "The machine restarts with \(game.title), replacing “\(machine.discNames[0] ?? "")”. Anything unsaved there is lost (Quick Save, ⇧⌘F6, keeps it).",
                              button: "Play") else { return }
            }
            launch(machine)
        }
    }

    static func play(_ game: PersonalGame, openMachine: @escaping () -> Void) {
        guard let url = ClassicsLibrary.shared.myGames.discURL(game) else { return }
        let launch: (MachineController) -> Void = { $0.play(game, disc: url) }
        guard let machine = MachineController.frontmost else {
            MachineController.pendingLaunch = launch
            openMachine()
            return
        }
        if machine.isPlayingSomething && machine.snapshotOwner?.id != game.id {
            guard confirm("Play \(game.title)?",
                          detail: "The machine restarts with \(game.title), replacing “\(machine.discNames[0] ?? "")”. Anything unsaved there is lost (Quick Save, ⇧⌘F6, keeps it).",
                          button: "Play") else { return }
        }
        launch(machine)
    }

    static func restore(_ snapshot: SnapshotManifest, title: String, openMachine: @escaping () -> Void) {
        guard let machine = MachineController.frontmost else {
            MachineController.pendingLaunch = { $0.quickLoad(snapshot) }
            openMachine()
            return
        }
        if machine.isPlayingSomething && machine.snapshotOwner?.id != snapshot.owner {
            guard confirm("Restore \(title)?",
                          detail: "The machine is replaced by the snapshot, and “\(machine.discNames[0] ?? "")” is taken out. Anything unsaved there is lost.",
                          button: "Restore") else { return }
        }
        machine.quickLoad(snapshot)
        NotificationCenter.default.post(name: EmulatorNSView.bringToFront, object: machine.host)
    }

    private static func confirm(_ message: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
