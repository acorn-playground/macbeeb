import BeebLibrary
import CGtk
import Foundation

// The books on the shelves: a cover, standing on the shelf, and its title
// and state below (nothing's drawn over the artwork).

enum ShelfMetrics {
    static let coverWidth = 172.0
    static let coverHeight = 210.0
    /// A tile: its cover and the padding around it.
    static let tileWidth: Int32 = 188
}

/// A tile in a shelf's grid: the grid's child (focusable, selectable),
/// holding the tile at its width.
@MainActor
func shelfChild(_ tile: Widget) -> Widget {
    let child = Widget(gtk_flow_box_child_new())
    tile.size(width: ShelfMetrics.tileWidth)
    // (At most the tile's width: the grid sizes its columns by it.)
    gtk_flow_box_child_set_child(cast(child.widget), Clamp(tile, maximum: ShelfMetrics.tileWidth).widget)
    return child
}

/// A tile's state below its title: a label with an icon, coloured, or a
/// link-like button.
@MainActor
enum ShelfTileStatus {
    static func label(_ text: String, icon: String?, style: String?) -> Widget {
        let box = Box(.horizontal, spacing: 4) {
            if let icon { Icon(icon, size: 12) }
            Label(text).ellipsize()
        }
        .align(horizontal: GTK_ALIGN_CENTER)
        .style("tile-status")
        if let style { box.style(style) }
        return box
    }

    static func link(_ text: String, icon: String, tooltip: String, _ action: @escaping @MainActor () -> Void) -> Widget {
        Button(text, icon: icon, action)
            .style("flat", "tile-link")
            .tooltip(tooltip)
            .align(horizontal: GTK_ALIGN_CENTER)
    }
}

// MARK: The Classics

/// One book on an archive shelf: a game's cover, or the archive's.
@MainActor
final class ShelfTile {
    let entry: ShelfEntry
    /// Its rank or place on this shelf.
    let number: Int?
    /// The grid's child.
    let child: Widget
    private let tile: Box
    private let cover: ShelfCover
    private let status = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    private var built: Set<String> = []

    init(entry: ShelfEntry, number: Int?) {
        self.entry = entry
        self.number = number
        let cover = switch entry {
        case .game(let game):
            ShelfCover.classic(game, width: ShelfMetrics.coverWidth, height: ShelfMetrics.coverHeight)
        case .archive:
            ShelfCover(width: ShelfMetrics.coverWidth, height: ShelfMetrics.coverHeight, content: .archive)
        }
        self.cover = cover
        let status = status
        let title = Label(Self.title(of: entry)).style("tile-title").ellipsize()
        let heading = Box(.horizontal, spacing: 6) {
            if let number {
                Label("\(number)", style: "dim-label", "numeric", "tile-title")
            }
            title
        }
        .align(horizontal: GTK_ALIGN_CENTER)
        gtk_stack_set_transition_duration(cast(status.widget), 250)
        status.sizesToVisible()
        tile = Box(.vertical, spacing: 8) {
            cover.box
            Box(.vertical, spacing: 3) {
                heading
                status
            }
        }
        tile.style("shelf-tile")
        child = shelfChild(tile)
        child.keep(self)
        follow()
    }

    private static func title(of entry: ShelfEntry) -> String {
        switch entry {
        case .game(let game): game.title
        case .archive: "BBCMicro.co.uk"
        }
    }

    // MARK: State

    private enum Shown: Equatable {
        case archive
        case added
        case get
        case waiting
        case importing
        case resume(SnapshotManifest)
        case ready
        case hardware
    }

    private func follow() {
        let classics = ClassicsLibrary.shared
        let entry = entry
        child.libraryTrack({ () -> Shown in
            guard case .game(let game) = entry else { return .archive }
            if classics.justInstalled == game.id { return .added }
            switch classics.state(of: game) {
            case .notInstalled: return .get
            case .waiting: return .waiting
            case .importing: return .importing
            case .installed: return classics.latestSnapshot(of: game).map { .resume($0) } ?? .ready
            case .hardwareUnavailable: return .hardware
            }
        }) { [self] shown in
            show(shown)
        }
        child.libraryTrack({ () -> [Bool] in
            guard case .game(let game) = entry else { return [true, false] }
            return [classics.installed[game.id] != nil, classics.justInstalled == game.id]
        }) { [cover] flags in
            cover.area.setStyle("not-installed", !flags[0])
            cover.area.setStyle("just-installed", flags[1])
        }
    }

    private func show(_ shown: Shown) {
        let name: String
        switch shown {
        case .archive: name = "archive"
        case .added: name = "added"
        case .get: name = "get"
        case .waiting: name = "waiting"
        case .importing: name = "importing"
        case .resume(let snapshot): name = "resume-\(snapshot.id)"
        case .ready: name = "ready"
        case .hardware: name = "hardware"
        }
        if !built.contains(name) {
            built.insert(name)
            status.add(makeStatus(shown), name: name)
        }
        status.visible = name
        let text = statusText(shown)
        child.tooltip(helpText(text))
        child.accessibleLabel(accessibilityLabel(text))
    }

    private func makeStatus(_ shown: Shown) -> Widget {
        guard case .game(let game) = entry else {
            return ShelfTileStatus.label("Explore the archive ↗", icon: nil, style: "accent")
        }
        let classics = ClassicsLibrary.shared
        switch shown {
        case .archive, .added:
            return ShelfTileStatus.label("Added to your library", icon: "object-select-symbolic", style: "success")
        case .get:
            return ShelfTileStatus.link("Get", icon: "folder-download-symbolic", tooltip: "Get \(game.title) from its BBCMicro.co.uk page") {
                classics.get(game)
            }
        case .waiting:
            return ShelfTileStatus.label("Waiting for download…", icon: "preferences-system-time-symbolic", style: "warning")
        case .importing:
            return ShelfTileStatus.label("Importing…", icon: "folder-download-symbolic", style: "warning")
        case .resume(let snapshot):
            return ShelfTileStatus.link("Resume", icon: "document-open-recent-symbolic",
                                   tooltip: "Carry on from the snapshot saved \(LibraryDates.snapshot(snapshot.created))") {
                LibraryPlayer.restore(snapshot, title: game.title)
            }
        case .ready:
            return ShelfTileStatus.label("Ready to play", icon: "object-select-symbolic", style: "success")
        case .hardware:
            return ShelfTileStatus.label("Needs other hardware", icon: "dialog-warning-symbolic", style: "dim-label")
        }
    }

    private func statusText(_ shown: Shown) -> String {
        switch shown {
        case .archive: "Explore the archive ↗"
        case .added: "Added to your library"
        case .get: "Get from BBCMicro.co.uk"
        case .waiting: "Waiting for download…"
        case .importing: "Importing…"
        case .resume: "Ready to resume"
        case .ready: "Ready to play"
        case .hardware: "Needs other hardware"
        }
    }

    private func helpText(_ status: String) -> String {
        switch entry {
        case .game(let game):
            (number.map { "#\($0) " } ?? "") + game.title + (game.editionLabel.map { " (\($0))" } ?? "") + " — \(status)"
        case .archive(let book):
            book.pitch
        }
    }

    private func accessibilityLabel(_ status: String) -> String {
        switch entry {
        case .game(let game): (number.map { "Number \($0), " } ?? "") + "\(game.title). \(status)."
        case .archive(let book): "\(book.title), BBCMicro.co.uk. \(book.subtitle)."
        }
    }
}

// MARK: My Games

/// One of My Games on the shelf. Dropping a disc or picture on it gives it
/// that disc or cover.
@MainActor
final class PersonalTile {
    let game: PersonalGame
    let child: Widget
    private let tile: Box

    init(game: PersonalGame) {
        self.game = game
        let cover = ShelfCover.personal(game, width: ShelfMetrics.coverWidth, height: ShelfMetrics.coverHeight)
        let status = Bin()
        tile = Box(.vertical, spacing: 8) {
            cover.box
            Box(.vertical, spacing: 3) {
                Label(game.title).style("tile-title").ellipsize().centred()
                status
            }
        }
        tile.style("shelf-tile")
        child = shelfChild(tile)
        child.keep(self)
        child.keep(cover)
        child.tooltip(game.discFile == nil ? "\(game.title): drop its disc image here" : "\(game.title): drop a picture here for its cover")
        child.accessibleLabel("\(game.title), my game. \(game.discFile == nil ? "No disc yet." : "Ready to play.")")

        let classics = ClassicsLibrary.shared
        let id = game.id
        child.libraryTrack({ classics.latestSnapshots[id] }) { latest in
            if game.discFile == nil {
                status.child = ShelfTileStatus.label("No disc yet: drop one here", icon: "media-optical-symbolic", style: "dim-label")
            } else if let latest {
                status.child = ShelfTileStatus.link("Resume", icon: "document-open-recent-symbolic",
                                               tooltip: "Carry on from the snapshot saved \(LibraryDates.snapshot(latest.created))") {
                    LibraryPlayer.restore(latest, title: game.title)
                }
            } else {
                status.child = ShelfTileStatus.label("Ready to play", icon: "object-select-symbolic", style: "success")
            }
        }

        // Drops: its disc, or its cover.
        let tile = tile
        let drop = DropTarget.files { urls, _, _ in
            tile.removeStyle("drop-hover")
            return classics.attach(urls, to: game)
        }
        drop.onHover { tile.setStyle("drop-hover", $0) }
        child.add(drop)

        child.libraryContextMenu { [child] in
            let actions = LibraryActions(on: child, prefix: "game")
            return Menu {
                MenuSection {
                    MenuItem("Edit…", actions.add("edit") { classics.edit(game) })
                    MenuItem(game.discFile == nil ? "Choose Disc…" : "Replace Disc…",
                             actions.add("disc") { classics.chooseDisc(for: game) })
                    MenuItem(game.coverFile == nil ? "Add Cover…" : "Change Cover…",
                             actions.add("cover") { classics.chooseCover(for: game) })
                }
                MenuSection {
                    MenuItem("Remove…", actions.add("remove") { classics.remove(game) })
                }
            }
        }
    }
}

/// The empty book at the end of My Games: drop discs and pictures on it, or
/// click it to choose them.
@MainActor
final class AddGameTile {
    let child: Widget

    init() {
        let classics = ClassicsLibrary.shared
        // The plus and its words, in the middle of an empty book.
        let well = Box(.vertical) {
            Box(.vertical, spacing: 10) {
                Icon("list-add-symbolic", size: 32)
                Label("Drop disc images or cover pictures here").wrap().centred().style("caption").maxWidthChars(14)
            }
            .align(vertical: GTK_ALIGN_CENTER)
            .expand(vertical: true)
            .margin(horizontal: 12)
        }
        .style("add-game-well")
        .align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_END)
        .size(width: Int32((ShelfMetrics.coverHeight * 0.7).rounded()), height: Int32(ShelfMetrics.coverHeight))
        let tile = Box(.vertical, spacing: 8) {
            Bin(well).size(width: Int32(ShelfMetrics.coverWidth), height: Int32(ShelfMetrics.coverHeight))
            Box(.vertical, spacing: 3) {
                Label("Add a Game").style("tile-title").centred()
                // (As tall as a tile's state.)
                Label(" ").style("tile-status")
            }
        }
        tile.style("shelf-tile")
        child = shelfChild(tile)
        child.tooltip("Add disc images and cover pictures: Classics MacBeeb recognises, or your own games")
        child.accessibleLabel("Add a game: choose disc images and cover pictures")
        child.onClick { _, _, _ in classics.chooseFiles() }
        let drop = DropTarget.files { urls, _, _ in
            tile.removeStyle("drop-hover")
            let wanted = urls.filter { MyGames.isDiscName($0) || MyGames.isCoverName($0) }
            classics.addFiles(wanted)
            return !wanted.isEmpty
        }
        drop.onHover { tile.setStyle("drop-hover", $0) }
        child.add(drop)
    }
}
