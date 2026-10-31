import BeebCore
import BeebHost
import Foundation
import Observation

/// What's on the discs in a machine's drives, for the disc contents
/// window, and the changes made there. A change waits for the drive to be
/// idle, then goes in as if the disc were swapped for one with the change
/// made (and back to its file, if it came from one).
@MainActor
@Observable
final class DiscContentsModel {
    let machine: MachineController

    /// The BBC's drive number: 0 and 1, or 2 and 3 for a DFS disc's
    /// second side.
    var surface = 0 {
        didSet {
            if surface != oldValue {
                path = []
                selection = []
            }
        }
    }
    var drive: Int { surface % 2 }
    var side: Int { surface / 2 }

    /// The ADFS directories opened from the root, innermost last.
    var path: [(name: String, sector: Int)] = []
    var location: DiscVolume.Location {
        DiscVolume.Location(side: side, directory: path.last?.sector ?? ADFSDisc.rootSector)
    }

    /// Each drive's disc, or why it can't be shown.
    private(set) var volumes: [Int: Result<DiscVolume, Error>] = [:]
    var volume: DiscVolume? { try? volumes[drive]?.get() }
    private(set) var items: [DiscVolume.Item] = []
    var selection: Set<String> = []
    var sortOrder: [DiscSort] = [DiscSort(key: "name", ascending: true)] {
        didSet { sortItems() }
    }

    /// Waiting for the drive to be idle before making a change.
    private(set) var waiting = false
    /// Set once an ADFS disc's been changed while the BBC might have it
    /// mounted: it'll say "Disc changed" until *MOUNT.
    private(set) var adfsChanged: Set<Int> = []
    var alert: String?

    init(machine: MachineController) {
        self.machine = machine
    }

    /// The drives that can be shown: 0 and 1, and 2 and 3 when there's a
    /// double-sided DFS disc in 0 or 1.
    var surfaces: [Int] {
        [0, 1] + [0, 1].filter { (try? volumes[$0]?.get())?.sideCount == 2 }.map { $0 + 2 }
    }

    /// Why the disc can't be listed, if it can't.
    var problem: String? {
        switch volumes[drive] {
        case nil: return machine.discNames[drive] == nil ? "There’s no disc in drive \(drive)." : nil
        case .failure(let error): return error.localizedDescription
        case .success(let volume):
            if side >= volume.sideCount { return "There’s no disc in drive \(drive)." }
            return nil
        }
    }

    // MARK: Reading

    private var reading = false
    private var readAgain = false

    /// Reads both drives' discs again (coalescing a burst of requests).
    func reload() {
        guard !reading else {
            readAgain = true
            return
        }
        reading = true
        let host = machine.host
        Task {
            var read: [Int: Result<DiscVolume, Error>] = [:]
            for drive in 0..<2 {
                do {
                    if let volume = try await host.readVolume(drive: drive) {
                        read[drive] = .success(volume)
                    }
                } catch {
                    read[drive] = .failure(error)
                }
            }
            volumes = read
            if !surfaces.contains(surface) {
                surface = drive
            }
            refreshItems()
            reading = false
            if readAgain {
                readAgain = false
                reload()
            }
        }
    }

    private func refreshItems() {
        guard let volume, side < volume.sideCount else {
            items = []
            return
        }
        // A directory that's gone (deleted on the BBC) takes us back out.
        while true {
            do {
                items = try volume.items(at: location)
                break
            } catch {
                if path.isEmpty {
                    items = []
                    break
                }
                path.removeLast()
            }
        }
        sortItems()
        selection.formIntersection(items.map(\.id))
    }

    private func sortItems() {
        items.sort { a, b in
            for descriptor in sortOrder {
                let order: ComparisonResult = switch descriptor.key {
                case "load": compare(a.loadAddress, b.loadAddress)
                case "exec": compare(a.executionAddress, b.executionAddress)
                case "length": compare(a.length, b.length)
                case "access": a.access.compare(b.access)
                default: a.name.localizedStandardCompare(b.name)
                }
                if order != .orderedSame {
                    return descriptor.ascending == (order == .orderedAscending)
                }
            }
            return false
        }
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    var title: String { volume?.title(side: side) ?? "" }
    var bootOption: Int { volume?.bootOption(side: side) ?? 0 }

    var freeSpace: String {
        guard let volume else { return "" }
        let bytes = volume.freeSectors(side: side) * 256
        let files = volume.isADFS ? "" : " · \(items.count) of \(DFSDisc.maxFiles) files"
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary) + " free" + files
    }

    func open(_ item: DiscVolume.Item) {
        guard item.isDirectory else { return }
        path.append((item.name, item.startSector))
        selection = []
        refreshItems()
    }

    func goUp(to depth: Int) {
        path.removeLast(path.count - depth)
        selection = []
        refreshItems()
    }

    var selectedItems: [DiscVolume.Item] { items.filter { selection.contains($0.id) } }

    // MARK: Changing

    /// Makes a change to the disc in the drive shown, when the drive's
    /// idle. Undo puts the disc back as it was, unless the BBC has written
    /// to it since.
    func change(_ name: String, drive: Int? = nil, undoManager: UndoManager?,
                _ body: @escaping @Sendable (inout DiscVolume) throws -> Void) {
        let drive = drive ?? self.drive
        let host = machine.host
        Task {
            waiting = true
            defer { waiting = false }
            for _ in 0..<60 {
                do {
                    switch try await host.changeVolume(drive: drive, body) {
                    case .changed(let before, let after):
                        if after.isADFS {
                            adfsChanged.insert(drive)
                        }
                        registerUndo(name, drive: drive, restoring: before, over: after, undoManager: undoManager)
                        reload()
                        return
                    case .noDisc:
                        reload()
                        return
                    case .busy:
                        try await Task.sleep(for: .milliseconds(250))
                    }
                } catch {
                    alert = error.localizedDescription
                    reload()
                    return
                }
            }
            alert = "Drive \(drive) is still in use, so the disc can’t be changed. Try again when the BBC’s finished with it"
                + (machine.isStill ? ", and the machine’s running again." : ".")
        }
    }

    private func registerUndo(_ name: String, drive: Int, restoring before: DiscVolume, over after: DiscVolume,
                              undoManager: UndoManager?) {
        guard let undoManager else { return }
        let expected = Self.trimmed(after.image)
        undoManager.registerUndo(withTarget: self) { model in
            model.change(name, drive: drive, undoManager: undoManager) { volume in
                guard Self.trimmed(volume.image) == expected else { throw UndoError.changedSince }
                volume = before
            }
        }
        undoManager.setActionName(name)
    }

    enum UndoError: Error, LocalizedError {
        case changedSince
        var errorDescription: String? { "The disc has been written to since, so that can’t be undone." }
    }

    private nonisolated static func trimmed(_ image: [UInt8]) -> ArraySlice<UInt8> {
        image[..<((image.lastIndex { $0 != 0 } ?? -1) + 1)]
    }

    func setTitle(_ title: String, undoManager: UndoManager?) {
        guard title != self.title else { return }
        let side = side
        change("Change Title", undoManager: undoManager) { $0.setTitle(title, side: side) }
    }

    func setBootOption(_ option: Int, undoManager: UndoManager?) {
        guard option != bootOption else { return }
        let side = side
        change("Change Boot Option", undoManager: undoManager) { $0.setBootOption(option, side: side) }
    }

    func delete(_ items: [DiscVolume.Item], undoManager: UndoManager?) {
        guard !items.isEmpty else { return }
        let location = location
        change(items.count == 1 ? "Delete “\(items[0].name)”" : "Delete \(items.count) Files", undoManager: undoManager) {
            volume in
            for item in items {
                try volume.delete(item, at: location)
            }
        }
    }

    func update(_ item: DiscVolume.Item, name: String, loadAddress: UInt32, executionAddress: UInt32, locked: Bool,
                undoManager: UndoManager?) {
        let location = location
        change("Change “\(item.name)”", undoManager: undoManager) { volume in
            try volume.update(item, at: location, loadAddress: loadAddress, executionAddress: executionAddress,
                              locked: locked)
            if name != item.name {
                try volume.rename(item, at: location, to: name)
            }
        }
    }

    func createDirectory(named name: String, undoManager: UndoManager?) {
        let location = location
        change("New Directory", undoManager: undoManager) { try $0.createDirectory(at: location, name: name) }
    }

    /// Adds Mac files (and, on ADFS, folders), named and addressed by
    /// .inf files beside them where there are any.
    func add(_ urls: [URL], undoManager: UndoManager?) {
        let isADFS = volume?.isADFS ?? false
        let incoming: [MacFile]
        do {
            incoming = try urls.compactMap { try MacFile.read($0, adfs: isADFS) }
        } catch {
            alert = error.localizedDescription
            return
        }
        guard !incoming.isEmpty else {
            if urls.contains(where: \.hasDirectoryPath) && !isADFS {
                alert = "DFS discs can’t hold folders."
            }
            return
        }
        let location = location
        change(incoming.count == 1 ? "Add “\(incoming[0].name)”" : "Add \(incoming.count) Files",
               undoManager: undoManager) { volume in
            for item in incoming {
                try item.add(to: &volume, at: location)
            }
        }
    }

    // MARK: Taking files out

    /// Whether an item is a tokenised BASIC program.
    func isBASIC(_ item: DiscVolume.Item) -> Bool {
        guard !item.isDirectory, let volume else { return false }
        return BBCBasic.isProgram(volume.contents(of: item, at: location))
    }

    /// Saves a BASIC program as text, where the user says.
    func exportAsText(_ item: DiscVolume.Item) {
        guard let volume else { return }
        let text = BBCBasic.list(volume.contents(of: item, at: location))
        Platform.chooseSaveLocation(.basicText, suggestedName: InfFile.macName(item.name) + ".bas",
                                    message: "The program listed as text, a line per line, as LIST shows it.") { url in
            guard let url else { return }
            do {
                try Data(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }).write(to: url)
            } catch {
                Platform.showError(error)
            }
        }
    }

    /// Writes items into `folder`, each file with a .inf beside it, and
    /// ADFS directories as folders. Returns the files written.
    @discardableResult
    func export(_ items: [DiscVolume.Item], to folder: URL) throws -> [URL] {
        guard let volume else { return [] }
        return try Self.export(items, from: volume, at: location, to: folder)
    }

    nonisolated static func export(_ items: [DiscVolume.Item], from volume: DiscVolume, at location: DiscVolume.Location,
                                   to folder: URL) throws -> [URL] {
        try items.map { item in
            let url = folder.appendingPathComponent(InfFile.macName(item.name))
            try write(item, from: volume, at: location, to: url)
            return url
        }
    }

    /// Writes one item at `url`: a file with its .inf beside it, or an ADFS
    /// directory as a folder of them.
    nonisolated static func write(_ item: DiscVolume.Item, from volume: DiscVolume, at location: DiscVolume.Location,
                                  to url: URL) throws {
        if item.isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var inner = location
            inner.directory = item.startSector
            _ = try export((try? volume.items(at: inner)) ?? [], from: volume, at: inner, to: url)
        } else {
            try Data(volume.contents(of: item, at: location)).write(to: url)
            let inf = InfFile(name: item.fullName, loadAddress: item.loadAddress,
                              executionAddress: item.executionAddress, length: item.length, locked: item.locked)
            try Data(inf.text.utf8).write(to: url.appendingPathExtension("inf"))
        }
    }
}
