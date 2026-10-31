import BeebCore
import BeebLibrary
import BeebROMs
import Foundation
import Observation
#if canImport(Glibc)
import Glibc
#endif

/// The BBC Micro Classics bookshelf's state, shared by every window: the
/// library of imported games, downloads being waited for, the Downloads
/// watcher, and the quick save store.
@MainActor @Observable
final class ClassicsLibrary {
    static let shared = ClassicsLibrary()

    let catalogue = Catalogue.classics
    @ObservationIgnored let library = GameLibrary(root: GameLibrary.defaultRoot)
    @ObservationIgnored let snapshots = SnapshotStore(root: SnapshotStore.defaultRoot)
    @ObservationIgnored let media = MediaRegistry(url: MediaRegistry.defaultURL)
    @ObservationIgnored let myGames = MyGames(root: MyGames.defaultRoot)

    /// The user's own games, in the order they were added.
    private(set) var personalGames: [PersonalGame] = []
    /// Games waiting for the user to fill in their details, first first.
    var drafts: [GameDraft] = []

    /// Installed games, by game ID.
    private(set) var installed: [String: InstalledGame] = [:]
    /// Games whose pages the user's been sent to, by game ID.
    private(set) var pending: [String: PendingDownload] = [:]
    /// Games being imported.
    private(set) var importing: Set<String> = []
    /// The game most recently added, for a moment's confirmation.
    private(set) var justInstalled: String?
    /// Downloaded discs MacBeeb doesn't recognise, found while waiting for
    /// a download: the user says which game each is.
    private(set) var unresolved: [DiskCandidate] = []
    /// Bumped when any game's quick saves change.
    private(set) var snapshotChanges = 0
    /// Each library game's newest snapshot, by owner (a Classic's library ID
    /// or one of My Games' IDs).
    private(set) var latestSnapshots: [UUID: SnapshotManifest] = [:]

    // MARK: Settings

    private static let autoDetectKey = "MacBeebClassicsAutoDetect"
    private static let folderKey = "MacBeebClassicsDownloadFolder"
    /// Whether to watch for downloaded games; nil until the user's been
    /// asked. (The app preference: macOS's own permission is separate.)
    var autoDetect: Bool? {
        didSet {
            UserDefaults.standard.set(autoDetect, forKey: Self.autoDetectKey)
            updateWatcher()
        }
    }

    /// The folder watched: Downloads unless the user chose another.
    var downloadFolder: URL {
        didSet {
            UserDefaults.standard.set(downloadFolder == Self.defaultDownloadFolder ? nil : downloadFolder.path,
                                      forKey: Self.folderKey)
            updateWatcher()
        }
    }

    static var defaultDownloadFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appendingPathComponent("Downloads")
    }

    enum WatchState: Equatable {
        case off
        case watching
        /// The folder can't be read (macOS said no, or it's gone).
        case noAccess(String)
    }

    private(set) var watchState = WatchState.off
    @ObservationIgnored private var watcher: DownloadsWatcher?

    private init() {
        autoDetect = UserDefaults.standard.object(forKey: Self.autoDetectKey) as? Bool
        downloadFolder = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0) }
            ?? Self.defaultDownloadFolder
        Task {
            await snapshots.recover()
            await refresh()
            updateWatcher()
        }
        NotificationCenter.default.addObserver(forName: Platform.didBecomeActive, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.watcher?.scanSoon()
            }
        }
    }

    /// Re-reads the library, dropping games whose copies have gone.
    func refresh() async {
        _ = try? await library.reconcile()
        let games = await library.installed
        installed = Dictionary(uniqueKeysWithValues: games.map { ($0.gameID, $0) })
        let waiting = await library.pending()
        pending = Dictionary(uniqueKeysWithValues: waiting.map { ($0.gameID, $0) })
        try? await myGames.reconcile()
        personalGames = await myGames.games
        await loadLatestSnapshots()
    }

    private func loadLatestSnapshots() async {
        var latest: [UUID: SnapshotManifest] = [:]
        for owner in installed.values.map(\.libraryID) + personalGames.map(\.id) {
            if let newest = await snapshots.history(owner: owner).first {
                latest[owner] = newest
            }
        }
        latestSnapshots = latest
    }

    /// The newest snapshot of a Classic, if it's installed and has one.
    func latestSnapshot(of game: CuratedGame) -> SnapshotManifest? {
        installed[game.id].flatMap { latestSnapshots[$0.libraryID] }
    }

    // MARK: States

    enum GameState: Equatable {
        case notInstalled
        case waiting
        case importing
        case installed(InstalledGame)
        /// Installed, but MacBeeb can't provide the machine it needs.
        case hardwareUnavailable(InstalledGame, String)
    }

    func state(of game: CuratedGame) -> GameState {
        if importing.contains(game.id) { return .importing }
        if let record = installed[game.id] {
            if let reason = Self.hardwareProblem(game) {
                return .hardwareUnavailable(record, reason)
            }
            return .installed(record)
        }
        return pending[game.id] != nil ? .waiting : .notInstalled
    }

    /// Why MacBeeb can't run `game` as it needs to be run, if it can't.
    static func hardwareProblem(_ game: CuratedGame) -> String? {
        let requirement = game.machine
        return requirement.unavailableReason(
            sidewaysRAMBanks: BeebROMs.configuration(for: requirement.model).sidewaysRAMBanks)
    }

    func installedGame(libraryID: UUID) -> InstalledGame? {
        installed.values.first { $0.libraryID == libraryID }
    }

    func personalGame(id: UUID) -> PersonalGame? {
        personalGames.first { $0.id == id }
    }

    /// The file of a disc kept by MacBeeb (a Classic's working copy, or one
    /// of My Games' discs) that has `id`, for a restored state to write
    /// back to, with what to call it.
    func managedDisc(id: UUID) async -> (url: URL, name: String, gameID: String?)? {
        if let record = installedGame(libraryID: id), let url = try? await library.prepareWorkingCopy(record) {
            return (url, catalogue.game(id: record.gameID)?.title ?? record.gameID, record.gameID)
        }
        if let game = personalGame(id: id), let url = myGames.discURL(game) {
            return (url, game.title, nil)
        }
        return nil
    }

    // MARK: Getting games

    /// Sends the user to the game's page to download it, and waits for it.
    func get(_ game: CuratedGame) {
        let go = { [self] in
            Task {
                try? await library.addPending(gameID: game.id)
                await refresh()
                watcher?.scanSoon()
            }
            Platform.open(game.archivePageURL)
        }
        guard autoDetect == nil else {
            go()
            return
        }
        Self.askToWatch { watch in
            self.autoDetect = watch
            go()
        }
    }

    func cancelWaiting(_ game: CuratedGame) {
        Task {
            try? await library.cancelPending(gameID: game.id)
            await refresh()
        }
    }

    /// Asks, in context, whether to watch Downloads.
    private static func askToWatch(_ completion: @escaping @MainActor (Bool) -> Void) {
        Platform.confirm(title: "Add downloaded games automatically?",
                         message: "To add games automatically, allow MacBeeb to look for downloaded disk images in your Downloads folder. It only reads them, and only while MacBeeb is open. You can always import manually, and change this in Settings.",
                         action: "Look for Downloads", cancel: "Not Now", destructive: false, completion: completion)
    }

    // MARK: My Games

    /// Adds dropped or chosen files: discs MacBeeb knows as Classics go
    /// there; other discs and pictures become My Games, whose details the
    /// user fills in.
    func addFiles(_ urls: [URL]) {
        let groups = MyGames.group(urls)
        guard !groups.isEmpty else { return }
        Task {
            for group in groups {
                var disc: DiscFile?
                if let url = group.disc {
                    do {
                        disc = try await Task.detached { try MyGames.readDisc(at: url) }.value
                    } catch {
                        Platform.showError(error)
                        continue
                    }
                }
                if let disc, catalogue.game(forDigest: disc.digest) != nil {
                    // A Classic: its own cover and settings apply.
                    let url = disc.url
                    if let candidate = try? await Task.detached(operation: { try GameLibrary.candidate(at: url) }).value {
                        try? await finishImport(candidate, as: nil, source: .dragAndDrop, onUnrecognised: nil)
                    }
                    continue
                }
                if let cover = group.cover {
                    do {
                        _ = try await Task.detached { try MyGames.checkCover(at: cover) }.value
                    } catch {
                        Platform.showError(error)
                        if disc == nil { continue }
                        drafts.append(GameDraft(disc: disc, cover: nil))
                        continue
                    }
                }
                drafts.append(GameDraft(disc: disc, cover: group.cover))
            }
        }
    }

    /// An unrecognised download, to fill in as one of My Games.
    func addToMyGames(_ candidate: DiskCandidate) {
        dismiss(candidate)
        addFiles([candidate.url])
    }

    /// File > Add to My Games…: disc images and pictures.
    func chooseFiles() {
        Platform.chooseFiles(.discsAndImages, multiple: true,
                             message: "Choose disc images and cover pictures. A disc and a picture with the same name make one game.") { urls in
            guard !urls.isEmpty else { return }
            self.addFiles(urls)
        }
    }

    /// Edits a game's details.
    func edit(_ game: PersonalGame) {
        drafts.append(GameDraft(editing: game, discName: game.discFile.map { _ in game.title },
                                cover: myGames.coverURL(game)))
    }

    /// Saves a draft: a new game, or changes to one.
    func save(_ draft: GameDraft) async -> Bool {
        do {
            if draft.isNew {
                try await myGames.add(draft.game, disc: draft.disc, cover: draft.newCover)
            } else {
                try await myGames.update(draft.game)
                if let disc = draft.disc { try await myGames.setDisc(disc, for: draft.game.id) }
                if let cover = draft.newCover { try await myGames.setCover(cover, for: draft.game.id) }
            }
        } catch {
            Platform.showError(error)
            return false
        }
        drafts.removeAll { $0.id == draft.id }
        await refresh()
        return true
    }

    func cancel(_ draft: GameDraft) {
        drafts.removeAll { $0.id == draft.id }
    }

    /// Adds the files dropped on one of My Games: a disc image gives it its
    /// disc, a picture its cover.
    func attach(_ urls: [URL], to game: PersonalGame) -> Bool {
        let disc = urls.first(where: MyGames.isDiscName)
        let cover = urls.first(where: MyGames.isCoverName)
        guard disc != nil || cover != nil else { return false }
        Task {
            do {
                if let disc {
                    let file = try await Task.detached { try MyGames.readDisc(at: disc) }.value
                    if game.discFile != nil, !(await confirmReplacingDisc(of: game)) { return }
                    try await myGames.setDisc(file, for: game.id)
                }
                if let cover {
                    try await myGames.setCover(cover, for: game.id)
                }
            } catch {
                Platform.showError(error)
            }
            await refresh()
        }
        return true
    }

    func chooseDisc(for game: PersonalGame) {
        Platform.chooseFiles(.discsOnly, multiple: false, message: "Choose the disc image for \(game.title).") { urls in
            guard let url = urls.first else { return }
            _ = self.attach([url], to: game)
        }
    }

    func chooseCover(for game: PersonalGame) {
        Platform.chooseFiles(.images, multiple: false, message: "Choose a cover picture for \(game.title).") { urls in
            guard let url = urls.first else { return }
            _ = self.attach([url], to: game)
        }
    }

    private func confirmReplacingDisc(of game: PersonalGame) async -> Bool {
        await Platform.confirm(title: "Replace \(game.title)’s disc?",
                               message: "MacBeeb’s copy of the old disc is deleted, with anything saved to it. Quick saves are kept, but may not suit the new disc.",
                               action: "Replace")
    }

    /// Deletes one of My Games, after asking. Its quick saves stay.
    func remove(_ game: PersonalGame) {
        Platform.confirm(title: "Remove \(game.title) from My Games?",
                         message: "MacBeeb’s copies of its disc and cover are deleted, with anything saved to the disc. The files you added it from aren’t touched, and its quick saves are kept.",
                         action: "Remove", cancel: "Cancel", destructive: true) { confirmed in
            guard confirmed else { return }
            Task {
                do {
                    try await self.myGames.remove(id: game.id)
                } catch {
                    Platform.showError(error)
                }
                await self.refresh()
            }
        }
    }

    /// Asks for disc images and imports them: as `game` if given, otherwise
    /// as whatever they're recognised as.
    func chooseAndImport(as game: CuratedGame? = nil) {
        let message = game.map { "Choose the disc image for \($0.title)." } ?? "Choose BBC Micro disc images to add."
        Platform.chooseFiles(.discsOnly, multiple: game == nil, message: message) { urls in
            for url in urls {
                self.importDisk(url, as: game, source: .filePicker)
            }
        }
    }

    /// Imports a disc image. Unrecognised discs ask which game they are
    /// (unless `game` says); `onUnrecognised` gets them instead, if given.
    func importDisk(_ url: URL, as game: CuratedGame? = nil, source: ImportSource,
                    onUnrecognised: ((DiskCandidate) -> Void)? = nil) {
        if let game { importing.insert(game.id) }
        Task {
            defer { if let game { importing.remove(game.id) } }
            do {
                let candidate = try await Task.detached { try GameLibrary.candidate(at: url) }.value
                try await finishImport(candidate, as: game, source: source, onUnrecognised: onUnrecognised)
            } catch {
                Platform.showError(error)
            }
        }
    }

    private func finishImport(_ candidate: DiskCandidate, as game: CuratedGame?, source: ImportSource,
                              onUnrecognised: ((DiskCandidate) -> Void)?) async throws {
        if let game, catalogue.game(forDigest: candidate.digest) == nil {
            // Not a disc MacBeeb knows: be sure before calling it this game.
            guard await Platform.confirm(title: "Add “\(candidate.fileName)” as \(game.title)?",
                                         message: "MacBeeb doesn’t recognise this disc as the edition from BBCMicro.co.uk. It may be a different version, or a different game. Add it as \(game.title) only if you’re sure it is.",
                                         action: "Add as \(game.title)") else { return }
        }
        let result = try await library.importCandidate(candidate, as: game?.id, source: source)
        switch result {
        case .installed(let record, _):
            unresolved.removeAll { $0.digest == candidate.digest }
            await refresh()
            celebrate(record.gameID)
        case .unrecognised(let candidate):
            if let onUnrecognised {
                onUnrecognised(candidate)
            } else {
                addUnresolved(candidate)
            }
        }
    }

    /// Settles an unrecognised download as `game`.
    func resolve(_ candidate: DiskCandidate, as game: CuratedGame) {
        importing.insert(game.id)
        Task {
            defer { importing.remove(game.id) }
            do {
                try await finishImport(candidate, as: game, source: .downloadsFolder, onUnrecognised: nil)
            } catch {
                Platform.showError(error)
            }
        }
    }

    func dismiss(_ candidate: DiskCandidate) {
        unresolved.removeAll { $0 == candidate }
    }

    private func addUnresolved(_ candidate: DiskCandidate) {
        guard !unresolved.contains(where: { $0.digest == candidate.digest }) else { return }
        unresolved.append(candidate)
        arrivals += 1
    }

    /// Counts downloads found in the watched folder that were added, or
    /// need the user to say what they are: the Game Library comes to the
    /// front for each (see `bringsLibraryForwardOnArrival`).
    private(set) var arrivals = 0

    private func celebrate(_ gameID: String) {
        arrivals += 1
        justInstalled = gameID
        Task {
            try? await Task.sleep(for: .seconds(4))
            if justInstalled == gameID { justInstalled = nil }
        }
    }

    /// Takes a game out of the library, after asking. Its quick saves stay.
    func remove(_ game: CuratedGame) {
        Platform.confirm(title: "Remove \(game.title) from the library?",
                         message: "MacBeeb’s copy of the disc is deleted, with anything the game saved to it. Your original download isn’t touched, and the game’s quick saves are kept.",
                         action: "Remove", cancel: "Cancel", destructive: true) { confirmed in
            guard confirmed else { return }
            Task {
                do {
                    try await self.library.remove(gameID: game.id)
                } catch {
                    Platform.showError(error)
                }
                await self.refresh()
            }
        }
    }

    func reveal(_ record: InstalledGame) {
        Task {
            let url = await library.pristineURL(record)
            Platform.reveal(url)
        }
    }

    func noteSnapshotsChanged() {
        snapshotChanges += 1
        Task { await loadLatestSnapshots() }
    }

    // MARK: Watching for downloads

    private func updateWatcher() {
        guard autoDetect == true else {
            watcher?.stop()
            watcher = nil
            watchState = .off
            return
        }
        if let watcher, watcher.folder == downloadFolder { return }
        watcher?.stop()
        let watcher = DownloadsWatcher(folder: downloadFolder) { [weak self] file in
            await self?.handleDownload(file) ?? true
        } onAccess: { [weak self] error in
            self?.watchState = error.map { .noAccess($0) } ?? .watching
        }
        self.watcher = watcher
        watcher.start()
    }

    /// A finished download: added if it's a game MacBeeb knows, offered for
    /// the user to identify if it turned up while a download was awaited.
    /// Returns whether it's been dealt with (false: look again when it
    /// changes).
    private func handleDownload(_ file: DownloadScanner.FileInfo) async -> Bool {
        let candidate: DiskCandidate
        do {
            candidate = try await Task.detached { try GameLibrary.candidate(at: file.url) }.value
        } catch {
            return true
        }
        // Changed while being read: it'll settle and come round again.
        guard candidate.byteCount == file.size else { return false }
        if let game = catalogue.game(forDigest: candidate.digest) {
            if installed[game.id]?.diskSHA256 == candidate.digest { return true }
            // Removed by the user: only a deliberate import brings it back.
            if await library.wasRemoved(digest: candidate.digest), pending[game.id] == nil { return true }
            importing.insert(game.id)
            defer { importing.remove(game.id) }
            if case .installed(let record, _)? = try? await library.importCandidate(candidate, source: .downloadsFolder) {
                await refresh()
                celebrate(record.gameID)
            }
            return true
        }
        // Unknown discs only matter if they arrived after the user went to
        // get something.
        let earliest = pending.values.map(\.requestedAt).min()
        if let earliest, file.modified >= earliest.addingTimeInterval(-60) {
            addUnresolved(candidate)
        }
        return true
    }
}

/// Watches one folder (not its subfolders) for finished disc image
/// downloads, while it's wanted. Folder events, the app becoming active and
/// starting up all just prompt another listing.
@MainActor
final class DownloadsWatcher {
    let folder: URL
    private let handle: (DownloadScanner.FileInfo) async -> Bool
    private let onAccess: (String?) -> Void
    private var scanner = DownloadScanner()
    #if canImport(Darwin)
    private var source: DispatchSourceFileSystemObject?
    #else
    private var source: DispatchSourceRead?
    #endif
    private var scanning = false
    private var rescan = false
    private var scheduled: Task<Void, Never>?
    private var stopped = false

    init(folder: URL, handle: @escaping (DownloadScanner.FileInfo) async -> Bool, onAccess: @escaping (String?) -> Void) {
        self.folder = folder
        self.handle = handle
        self.onAccess = onAccess
    }

    func start() {
        scanSoon(after: 0)
    }

    func stop() {
        stopped = true
        scheduled?.cancel()
        source?.cancel()
        source = nil
    }

    /// Lists the folder shortly; several requests make one listing.
    func scanSoon(after delay: Double = 0.5) {
        guard !stopped else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.scan()
        }
    }

    private func scan() async {
        guard !stopped else { return }
        if scanning {
            rescan = true
            return
        }
        scanning = true
        defer {
            scanning = false
            if rescan {
                rescan = false
                scanSoon()
            }
        }
        let folder = self.folder
        let listing: [DownloadScanner.FileInfo]
        do {
            // Off the main thread: the first look at Downloads waits for
            // macOS to ask the user.
            listing = try await Task.detached { try DownloadScanner.list(folder) }.value
        } catch {
            onAccess(error.localizedDescription)
            return
        }
        onAccess(nil)
        startSource()
        let result = scanner.update(listing: listing, now: Date())
        for file in result.ready where !stopped {
            if await handle(file) {
                scanner.markHandled(file)
            }
        }
        if result.settling {
            scanSoon(after: scanner.stabilityWindow + 0.25)
        }
    }

    #if canImport(Darwin)
    private func startSource() {
        guard source == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scanSoon()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.source = source
    }
    #else
    /// Linux: inotify, on the folder's entries being written, moved in or
    /// out, or deleted.
    private func startSource() {
        guard source == nil else { return }
        let fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard fd >= 0 else { return }
        let mask = UInt32(IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_DELETE | IN_CREATE)
        guard inotify_add_watch(fd, folder.path, mask) >= 0 else {
            close(fd)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            // Drain the events: any of them just means look again.
            var buffer = [UInt8](repeating: 0, count: 4096)
            while read(fd, &buffer, buffer.count) > 0 {}
            MainActor.assumeIsolated {
                self?.scanSoon()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.source = source
    }
    #endif
}

/// One of My Games being added or edited: its details, and any disc or
/// cover to copy in when it's saved.
struct GameDraft: Identifiable {
    var game: PersonalGame
    var isNew: Bool
    /// A disc to copy in.
    var disc: DiscFile?
    /// A picture to copy in.
    var newCover: URL?
    /// What the game has already (when editing).
    var existingDiscName: String?
    var existingCover: URL?

    var id: UUID { game.id }

    /// A new game, with its details guessed from its disc.
    init(disc: DiscFile?, cover: URL?) {
        var game = PersonalGame(title: disc?.suggestedTitle
                                ?? cover.map { $0.deletingPathExtension().lastPathComponent } ?? "")
        if let disc {
            (game.model, game.coprocessor) = disc.suggestedMachine
            game.start = disc.suggestedStart
        }
        self.game = game
        isNew = true
        self.disc = disc
        newCover = cover
    }

    init(editing game: PersonalGame, discName: String?, cover: URL?) {
        self.game = game
        isNew = false
        existingDiscName = discName
        existingCover = cover
    }

    var hasDisc: Bool { disc != nil || existingDiscName != nil }
    /// The cover to show: the new one, or the one it has.
    var shownCover: URL? { newCover ?? existingCover }
}
