import BeebLibrary
import CGtk
import Foundation
import Observation

// The details panel beside the shelves: the selected game's cover, what
// can be done with it, what it is, and its snapshots.

enum LibraryDetailMetrics {
    /// The panel's width, and its content's.
    static let width = 340.0
    static let margin: Int32 = 18
    static var contentWidth: Double { width - Double(margin) * 2 }
    static let coverHeight = 260.0
}

/// A game's quick saves and its disc's state, read from the library.
@MainActor @Observable
final class LibraryDetailHistory {
    var snapshots: [SnapshotManifest] = []
    var modified = false
}

@MainActor
enum LibraryDetails {
    /// The panel for nothing selected.
    static func empty() -> Widget {
        StatusPage(icon: "applications-games-symbolic", title: "No Game Selected",
                   description: "Choose a game on the shelf to see its details here.")
            .compact()
            .expand()
    }

    /// The panel's scrolling column.
    static func column(@WidgetList _ children: () -> [Widget]) -> Widget {
        let box = Box(.vertical, spacing: 14, children)
        box.margin(LibraryDetailMetrics.margin)
        return ScrolledWindow(box, horizontal: GTK_POLICY_NEVER).expand()
    }

    /// A large button across the panel: the main thing to do.
    static func primary(_ label: String, icon: String? = nil, _ action: @escaping @MainActor () -> Void) -> Button {
        Button(label, icon: icon, action).style("suggested-action", "pill")
    }

    static func secondary(_ label: String, icon: String? = nil, _ action: @escaping @MainActor () -> Void) -> Button {
        Button(label, icon: icon, action).style("pill")
    }

    /// Smaller actions, in a row that wraps.
    static func links(_ buttons: [Widget]) -> Widget {
        let wrap = WrapBox(spacing: 4, lineSpacing: 2)
        for button in buttons {
            wrap.append(button.style("flat", "detail-link"))
        }
        return wrap
    }

    static func link(_ label: String, tooltip: String? = nil, _ action: @escaping @MainActor () -> Void) -> Widget {
        Button(label, action).tooltip(tooltip)
    }

    /// A line of secondary text.
    static func note(_ text: String, style: String...) -> Label {
        let label = Label(text).wrap()
        for name in style { label.style(name) }
        return label
    }

    /// A spinner and what's happening.
    static func progress(_ text: String) -> Widget {
        Box(.horizontal, spacing: 8) {
            Spinner().size(width: 16, height: 16)
            Label(text, style: "dim-label")
        }
    }

    /// Facts as a list of properties.
    static func properties(_ rows: [(String, String, Bool)]) -> Widget {
        let list = ListBox()
        list.style("boxed-list")
        for (title, value, monospace) in rows {
            let row = ActionRow(title, subtitle: value).property().subtitleSelectable()
            if monospace { row.style("command-row") }
            list.append(row)
        }
        return list
    }

    /// The cover, at the top of the panel.
    static func coverBox(_ cover: ShelfCover) -> Widget {
        cover.box.align(horizontal: GTK_ALIGN_CENTER)
        return cover.box.margin(bottom: 4)
    }

    /// The title, and lines below it.
    static func heading(_ title: String, lines: [String]) -> Widget {
        let box = Box(.vertical, spacing: 4) {
            Label(title, style: "title-2").wrap()
            for line in lines {
                Label(line, style: "dim-label").wrap()
            }
        }
        box.accessibleLabel(([title] + lines).joined(separator: ", "))
        return box
    }

    /// Tells the machines playing a disc that its snapshots changed.
    static func snapshotsChanged(_ owner: UUID) {
        ClassicsLibrary.shared.noteSnapshotsChanged()
        for machine in MachineController.all.values where machine.snapshotOwner?.id == owner {
            machine.refreshSnapshotHistory()
        }
    }
}

// MARK: A Classic

@MainActor
enum GameDetailPanel {
    static func make(_ game: CuratedGame) -> Widget {
        let classics = ClassicsLibrary.shared
        let history = LibraryDetailHistory()
        let cover = ShelfCover.classic(game, width: LibraryDetailMetrics.contentWidth, height: LibraryDetailMetrics.coverHeight)
        var lines: [String] = []
        if let edition = game.editionLabel { lines.append(edition) }
        if let rank = game.rank { lines.append("#\(rank) in BBCMicro.co.uk’s top 20") }
        if let pick = classics.catalogue.authorsPicks.firstIndex(of: game.id) {
            lines.append("#\(pick + 1) of the Author’s Picks")
        }
        let actions = Bin()
        let snapshots = Bin()
        var facts: [(String, String, Bool)] = []
        if let publisher = game.publisher {
            facts.append(("Publisher", publisher + (game.year.map { ", \($0)" } ?? ""), false))
        }
        if let authors = game.authors { facts.append(("By", authors, false)) }
        facts.append(("Plays on", game.machine.summary, false))

        let panel = LibraryDetails.column {
            LibraryDetails.coverBox(cover)
            LibraryDetails.heading(game.title, lines: lines)
            actions
            LibraryDetails.note(game.description)
            LibraryDetails.properties(facts)
            LinkButton("View on BBCMicro.co.uk ↗", url: game.archivePageURL).align(horizontal: GTK_ALIGN_START).style("library-link")
            snapshots
            LibraryDetails.note("Disc and preservation work by BBCMicro.co.uk and its contributors.",
                                style: "dim-label", "caption")
        }
        panel.keep(cover)
        panel.keep(history)

        // The disc's snapshots, and whether the game's written to it.
        struct Load: Equatable {
            var record: UUID?
            var changes: Int
        }
        panel.libraryTrack({ Load(record: classics.installed[game.id]?.libraryID, changes: classics.snapshotChanges) }) { _ in
            Task {
                guard let record = classics.installed[game.id] else {
                    history.snapshots = []
                    history.modified = false
                    return
                }
                history.snapshots = await classics.snapshots.history(owner: record.libraryID)
                history.modified = await classics.library.workingCopyIsModified(record)
            }
        }

        struct Shown: Equatable {
            var state: ClassicsLibrary.GameState
            var justInstalled: Bool
            var autoDetect: Bool?
            var latest: SnapshotManifest?
            var modified: Bool
        }
        actions.libraryTrack({
            Shown(state: classics.state(of: game), justInstalled: classics.justInstalled == game.id,
                  autoDetect: classics.autoDetect, latest: history.snapshots.first, modified: history.modified)
        }) { shown in
            actions.child = makeActions(game, shown.state, justInstalled: shown.justInstalled, autoDetect: shown.autoDetect,
                                        latest: shown.latest, modified: shown.modified, history: history)
        }

        struct Listed: Equatable {
            var installed: Bool
            var snapshots: [SnapshotManifest]
        }
        snapshots.libraryTrack({ Listed(installed: classics.installed[game.id] != nil, snapshots: history.snapshots) }) { listed in
            snapshots.child = listed.installed || !listed.snapshots.isEmpty
                ? LibrarySnapshots.make(listed.snapshots, ownerTitle: game.title) : nil
        }
        return panel
    }

    private static func makeActions(_ game: CuratedGame, _ state: ClassicsLibrary.GameState, justInstalled: Bool,
                                    autoDetect: Bool?, latest: SnapshotManifest?, modified: Bool,
                                    history: LibraryDetailHistory) -> Widget {
        let classics = ClassicsLibrary.shared
        let box = Box(.vertical, spacing: 8)
        switch state {
        case .notInstalled:
            box.append(LibraryDetails.primary("Get from BBCMicro.co.uk ↗") { classics.get(game) })
            box.append(LibraryDetails.links([
                LibraryDetails.link("Import Disc…") { classics.chooseAndImport(as: game) },
            ]))
        case .waiting:
            box.append(LibraryDetails.note("Download the SSD from BBCMicro.co.uk. MacBeeb will add it automatically when it finishes."))
            if autoDetect != true {
                box.append(LibraryDetails.note("Looking for downloads is off, so import the disc once it’s downloaded.",
                                               style: "dim-label", "caption"))
            }
            box.append(LibraryDetails.primary("Open Page Again ↗") { Platform.open(game.archivePageURL) })
            box.append(LibraryDetails.progress("Waiting for download…"))
            box.append(LibraryDetails.links([
                LibraryDetails.link("Import Disc…") { classics.chooseAndImport(as: game) },
                LibraryDetails.link("Cancel Waiting") { classics.cancelWaiting(game) },
            ]))
        case .importing:
            box.append(LibraryDetails.progress("Importing…"))
        case .installed(let record):
            if justInstalled {
                box.append(ShelfTileStatus.label("Added to your library", icon: "object-select-symbolic", style: "success")
                    .align(horizontal: GTK_ALIGN_START))
            }
            box.append(LibraryDetails.primary("Play", icon: "media-playback-start-symbolic") {
                LibraryPlayer.play(game, record: record)
            })
            if let latest {
                box.append(LibraryDetails.secondary("Resume", icon: "document-open-recent-symbolic") {
                    LibraryPlayer.restore(latest, title: game.title)
                }
                .tooltip("Carry on from the snapshot saved \(LibraryDates.snapshot(latest.created))"))
            }
            if !record.verified {
                box.append(LibraryDetails.note("You chose this disc for \(game.title); MacBeeb didn’t recognise it as the BBCMicro.co.uk edition.",
                                               style: "dim-label", "caption"))
            }
            var links = [LibraryDetails.link("Reveal Disc") { classics.reveal(record) }]
            if modified {
                links.append(LibraryDetails.link("Revert Disc…",
                                                 tooltip: "Put the disc back as it was downloaded, undoing anything the game saved to it") {
                    revert(game, record, history: history)
                })
            }
            links.append(LibraryDetails.link("Remove…") { classics.remove(game) })
            box.append(LibraryDetails.links(links))
        case .hardwareUnavailable(let record, let reason):
            box.append(Box(.horizontal, spacing: 6) {
                Icon("dialog-warning-symbolic")
                Label("Requirements", style: "heading")
            })
            box.append(LibraryDetails.note(reason + " It won’t be run on other hardware."))
            box.append(LibraryDetails.links([
                LibraryDetails.link("Reveal Disc") { classics.reveal(record) },
                LibraryDetails.link("Remove…") { classics.remove(game) },
            ]))
        }
        return box
    }

    private static func revert(_ game: CuratedGame, _ record: InstalledGame, history: LibraryDetailHistory) {
        Platform.confirm(title: "Revert \(game.title)’s disc?",
                         message: "The disc goes back to how it was downloaded, losing anything the game saved to it. Quick saves aren’t affected. If the game is running, play it again afterwards.",
                         action: "Revert") { confirmed in
            guard confirmed else { return }
            let classics = ClassicsLibrary.shared
            Task {
                do {
                    try await classics.library.revertWorkingCopy(record)
                } catch {
                    Platform.showError(error)
                }
                history.modified = await classics.library.workingCopyIsModified(record)
            }
        }
    }
}

// MARK: The archive

@MainActor
enum ArchiveDetailPanel {
    static func make(_ book: ArchiveBook) -> Widget {
        let cover = ShelfCover(width: LibraryDetailMetrics.contentWidth, height: LibraryDetailMetrics.coverHeight, content: .archive)
        let panel = LibraryDetails.column {
            LibraryDetails.coverBox(cover)
            Label(book.title, style: "title-2").wrap()
            Label(book.pitch, style: "heading").wrap()
            LibraryDetails.primary("Visit BBCMicro.co.uk ↗") { Platform.open(book.url) }
            LibraryDetails.note(book.about)
            LibraryDetails.note("Game selection and preservation links courtesy of BBCMicro.co.uk. MacBeeb is an independent emulator and is not affiliated with the archive.",
                                style: "dim-label")
            LinkButton("About the BBC Micro Games Archive ↗", url: book.aboutURL).align(horizontal: GTK_ALIGN_START).style("library-link")
        }
        panel.keep(cover)
        return panel
    }
}

// MARK: One of My Games

@MainActor
enum PersonalDetailPanel {
    /// The panel for one of My Games, rebuilt as it changes (empty once
    /// it's gone).
    static func make(id: UUID) -> Widget {
        let classics = ClassicsLibrary.shared
        let bin = Bin().expand()
        bin.libraryTrack({ classics.personalGame(id: id) }) { game in
            bin.child = game.map(make) ?? LibraryDetails.empty()
        }
        return bin
    }

    private static func make(_ game: PersonalGame) -> Widget {
        let classics = ClassicsLibrary.shared
        let history = LibraryDetailHistory()
        let cover = ShelfCover.personal(game, width: LibraryDetailMetrics.contentWidth, height: LibraryDetailMetrics.coverHeight)
        let coverBox = LibraryDetails.coverBox(cover)
        coverBox.add(DropTarget.files { urls, _, _ in classics.attach(urls, to: game) })
        let byline = [game.publisher, game.year.map(String.init)].compactMap { $0 }.joined(separator: ", ")

        let play = Box(.vertical, spacing: 8)
        if game.discFile != nil {
            play.append(LibraryDetails.primary("Play", icon: "media-playback-start-symbolic") { LibraryPlayer.play(game) })
            let resume = Bin()
            play.append(resume)
            resume.libraryTrack({ history.snapshots.first }) { latest in
                resume.child = latest.map { latest in
                    LibraryDetails.secondary("Resume", icon: "document-open-recent-symbolic") {
                        LibraryPlayer.restore(latest, title: game.title)
                    }
                    .tooltip("Carry on from the snapshot saved \(LibraryDates.snapshot(latest.created))")
                }
            }
        } else {
            play.append(LibraryDetails.note("Add the game’s disc image to play it: drop it on the game, or choose it."))
            play.append(LibraryDetails.primary("Choose Disc…") { classics.chooseDisc(for: game) })
        }
        var edits = [LibraryDetails.link("Edit…") { classics.edit(game) }]
        if game.discFile != nil {
            edits.append(LibraryDetails.link("Replace Disc…") { classics.chooseDisc(for: game) })
        }
        edits.append(LibraryDetails.link(game.coverFile == nil ? "Add Cover…" : "Change Cover…") { classics.chooseCover(for: game) })
        var files: [Widget] = []
        if let url = classics.myGames.discURL(game) {
            files.append(LibraryDetails.link("Reveal Disc") { Platform.reveal(url) })
        }
        files.append(LibraryDetails.link("Remove…") { classics.remove(game) })

        let starts: (String, Bool) = switch game.start {
        case .boot: ("Booting the disc", false)
        case .insertOnly: ("Putting the disc in", false)
        case .type(let command): command.isEmpty ? ("Putting the disc in", false) : (command, true)
        }
        let snapshots = Bin()
        let panel = LibraryDetails.column {
            coverBox
            LibraryDetails.heading(game.title, lines: (byline.isEmpty ? [] : [byline]) + ["My game"])
            play
            Box(.vertical, spacing: 2) {
                LibraryDetails.links(edits)
                LibraryDetails.links(files)
            }
            LibraryDetails.properties([("Plays on", game.machineSummary, false), ("Starts by", starts.0, starts.1)])
            if let notes = game.notes {
                LibraryDetails.note(notes).selectable()
            }
            snapshots
        }
        panel.keep(cover)
        panel.keep(history)
        panel.libraryTrack({ classics.snapshotChanges }) { _ in
            Task { history.snapshots = await classics.snapshots.history(owner: game.id) }
        }
        snapshots.libraryTrack({ history.snapshots }) { list in
            snapshots.child = game.discFile != nil || !list.isEmpty ? LibrarySnapshots.make(list, ownerTitle: game.title) : nil
        }
        return panel
    }
}

// MARK: Snapshots

/// A disc's quick saves, newest first: their screenshots, each a button
/// that carries on from there.
@MainActor
enum LibrarySnapshots {
    static func make(_ snapshots: [SnapshotManifest], ownerTitle: String) -> Widget {
        let title = Box(.horizontal) {
            Label("Snapshots", style: "heading").expand(horizontal: true)
            if !snapshots.isEmpty {
                Button("Delete All…") { deleteAll(snapshots, ownerTitle: ownerTitle) }.style("flat", "detail-link")
            }
        }
        let box = Box(.vertical, spacing: 8) {
            title
            if snapshots.isEmpty {
                LibraryDetails.note("While it’s playing, Save and Load ▸ Quick Save (Alt+Shift+F6) saves the game exactly as it is, and Quick Load (Alt+Shift+F5) goes back to it. The last five are kept. (On some keyboards, hold Fn for F5 and F6.)",
                                    style: "dim-label", "caption")
            } else {
                LibraryDetails.note("Click one to carry on from there.", style: "dim-label", "caption")
            }
        }
        if !snapshots.isEmpty {
            let grid = Grid(rowSpacing: 12, columnSpacing: 10)
            gtk_grid_set_column_homogeneous(cast(grid.widget), 1)
            for (index, snapshot) in snapshots.enumerated() {
                grid.attach(LibrarySnapshotCard.make(snapshot, ownerTitle: ownerTitle), column: Int32(index % 2), row: Int32(index / 2))
            }
            box.append(grid)
        }
        return box.margin(top: 6)
    }

    private static func deleteAll(_ snapshots: [SnapshotManifest], ownerTitle: String) {
        guard let owner = snapshots.first?.owner else { return }
        Platform.confirm(title: "Delete all of \(ownerTitle)’s snapshots?", message: "This can’t be undone.",
                         action: "Delete", destructive: true) { confirmed in
            guard confirmed else { return }
            Task {
                try? await ClassicsLibrary.shared.snapshots.deleteAll(owner: owner)
                LibraryDetails.snapshotsChanged(owner)
            }
        }
    }
}

/// A snapshot as a button: its screenshot, and when it was saved.
@MainActor
enum LibrarySnapshotCard {
    static var width: Double { (LibraryDetailMetrics.contentWidth - 10) / 2 }

    static func make(_ snapshot: SnapshotManifest, ownerTitle: String) -> Widget {
        let width = width, height = (width / Renderer.aspect).rounded()
        let image = LibrarySnapshotImage()
        let picture = DrawingArea(width: Int32(width), height: Int32(height)) { cairo, width, height in
            guard let thumbnail = image.picture else { return }
            cairo.save()
            cairo.roundedRectangle(0, 0, width, height, radius: 6)
            cairo.clip()
            // Stretched to the box: the frame's pixels aren't square.
            thumbnail.draw(cairo, x: 0, y: 0, width: width, height: height)
            cairo.restore()
        }
        picture.style("snapshot-picture")
        picture.keep(image)
        picture.object.whenFinalised { [image] in image.alive = false }
        let play = Icon("media-playback-start-symbolic", size: 22)
            .style("snapshot-play")
            .align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER)
            .canTarget(false)
        let content = Box(.vertical, spacing: 4) {
            Overlay(picture) { play }
            Label(LibraryDates.snapshot(snapshot.created), style: "dim-label", "caption").ellipsize().maxWidthChars(1)
        }
        let restore: @MainActor () -> Void = { LibraryPlayer.restore(snapshot, title: ownerTitle) }
        let button = Button(child: content, restore)
            .style("flat", "snapshot-card")
            .align(horizontal: GTK_ALIGN_START)
            .tooltip("Carry on from here")
            .accessibleLabel("Snapshot from \(LibraryDates.spoken(snapshot.created)). Carries on from here.")
        button.libraryContextMenu { [button] in
            let actions = LibraryActions(on: button, prefix: "snapshot")
            return Menu {
                MenuSection {
                    MenuItem("Resume from Here", actions.add("resume", restore))
                }
                MenuSection {
                    MenuItem("Delete Snapshot", actions.add("delete") {
                        Task {
                            try? await ClassicsLibrary.shared.snapshots.delete(snapshot)
                            LibraryDetails.snapshotsChanged(snapshot.owner)
                        }
                    })
                }
            }
        }
        // The screenshot, read off the main thread.
        Task {
            guard let url = await ClassicsLibrary.shared.snapshots.thumbnailURL(snapshot) else { return }
            let read = await Task.detached { LibraryPicture(url: url, maxSize: 400) }.value
            guard image.alive else { return }
            image.picture = read
            picture.queueDraw()
        }
        return button
    }
}

@MainActor
private final class LibrarySnapshotImage {
    var picture: LibraryPicture?
    /// Until the card's gone.
    var alive = true
}
