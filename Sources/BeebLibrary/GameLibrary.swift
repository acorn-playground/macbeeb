import BeebCore
#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// A curated game's disc, copied into MacBeeb's library.
public struct InstalledGame: Codable, Sendable, Equatable, Identifiable {
    /// The library's own identity for this disc, independent of its name and
    /// contents (which the BBC may write to). Quick saves belong to it.
    public var libraryID: UUID
    public var gameID: String
    /// The pristine copy, in Games/.
    public var fileName: String
    /// The SHA-256 of the pristine copy.
    public var diskSHA256: String
    public var byteCount: Int64
    public var importedAt: Date
    public var source: ImportSource
    /// Whether the digest is one the catalogue knows (otherwise the user
    /// chose this disc for the game themselves).
    public var verified: Bool

    public var id: UUID { libraryID }
}

public enum ImportSource: String, Codable, Sendable {
    case downloadsFolder, dragAndDrop, filePicker
}

/// A game whose page the user went to, to download it.
public struct PendingDownload: Codable, Sendable, Equatable {
    public var gameID: String
    public var requestedAt: Date

    /// How long a pending download is waited for.
    public static let lifetime: TimeInterval = 24 * 60 * 60
}

/// A disc image read and checked, ready to import.
public struct DiskCandidate: Sendable, Equatable {
    public var url: URL
    public var digest: String
    public var byteCount: Int64
    public var format: Disc.ImageFormat
    public var data: Data

    public var fileName: String { url.lastPathComponent }
}

public enum ImportResult: Sendable, Equatable {
    /// In the library (now, or already, with the same disc).
    case installed(InstalledGame, alreadyInstalled: Bool)
    /// Not a disc the catalogue knows: the user has to say what it is.
    case unrecognised(DiskCandidate)
}

public enum ImportError: LocalizedError, Equatable {
    case notARegularFile(String)
    case unsupportedType(String)
    case tooLarge(String)
    case unreadable(String, String)
    case notADiscImage(String)
    /// The disc's a different curated game from the one chosen.
    case belongsToAnotherGame(fileName: String, game: String)
    case unknownGame(String)
    case libraryWriteFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notARegularFile(let name): "“\(name)” isn’t a disc image file."
        case .unsupportedType(let name): "“\(name)” isn’t a BBC Micro disc image (.ssd or .dsd)."
        case .tooLarge(let name): "“\(name)” is too large to be a BBC Micro disc image."
        case .unreadable(let name, let reason): "“\(name)” can’t be read: \(reason)"
        case .notADiscImage(let name): "“\(name)” doesn’t look like a BBC Micro disc image."
        case .belongsToAnotherGame(let name, let game): "“\(name)” is \(game), not this game."
        case .unknownGame(let id): "There’s no game “\(id)” in the catalogue."
        case .libraryWriteFailed(let reason): "MacBeeb couldn’t add the disc to its library: \(reason)"
        case .verificationFailed(let name): "The library’s copy of “\(name)” didn’t match the original, so it wasn’t added."
        }
    }
}

/// MacBeeb's library of curated games' discs, in Application Support:
///
///     Library/library.json   the index
///     Library/Games/         pristine copies, named by game and digest
///     Library/Working/       the copies that are played, which the BBC may write to
///
/// Originals (in Downloads, say) are only ever read.
public actor GameLibrary {
    public let root: URL
    public let catalogue: Catalogue
    private var index: Index
    private let fileManager = FileManager.default

    /// Disc images larger than this aren't considered (an 80-track DSD is
    /// 400K; ADFS L 640K).
    public static let maxImageSize: Int64 = 1 << 20
    /// The disc formats the bookshelf imports.
    public static let importableFormats: Set<Disc.ImageFormat> = [.ssd, .dsd]

    struct Index: Codable {
        var version = 1
        var installed: [InstalledGame] = []
        var pending: [PendingDownload] = []
        /// Digests of discs the user removed from the library: watching
        /// Downloads won't add them back (importing them by hand will).
        var removedDigests: [String] = []
    }

    public init(root: URL, catalogue: Catalogue = .classics) {
        self.root = root
        self.catalogue = catalogue
        let indexURL = root.appendingPathComponent("library.json")
        index = (try? JSONDecoder.library.decode(Index.self, from: Data(contentsOf: indexURL))) ?? Index()
    }

    /// Application Support/MacBeeb/Library.
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("MacBeeb/Library", isDirectory: true)
    }

    var gamesDirectory: URL { root.appendingPathComponent("Games", isDirectory: true) }
    var workingDirectory: URL { root.appendingPathComponent("Working", isDirectory: true) }

    // MARK: State

    public var installed: [InstalledGame] { index.installed }

    public func installed(gameID: String) -> InstalledGame? {
        index.installed.first { $0.gameID == gameID }
    }

    /// The pristine copy of an installed game's disc.
    public func pristineURL(_ game: InstalledGame) -> URL {
        gamesDirectory.appendingPathComponent(game.fileName)
    }

    /// Pending downloads that haven't expired.
    public func pending(now: Date = Date()) -> [PendingDownload] {
        index.pending.filter { now.timeIntervalSince($0.requestedAt) < PendingDownload.lifetime }
    }

    public func wasRemoved(digest: String) -> Bool {
        index.removedDigests.contains(digest)
    }

    /// Notes that the user's gone to get `gameID`. Asking again only
    /// refreshes the time.
    public func addPending(gameID: String, at date: Date = Date()) throws {
        index.pending.removeAll { $0.gameID == gameID }
        index.pending.append(PendingDownload(gameID: gameID, requestedAt: date))
        try save()
    }

    public func cancelPending(gameID: String) throws {
        index.pending.removeAll { $0.gameID == gameID }
        try save()
    }

    /// Drops expired pending downloads, and games whose copies have gone.
    /// Returns the games dropped.
    @discardableResult
    public func reconcile(now: Date = Date()) throws -> [InstalledGame] {
        let missing = index.installed.filter { !fileManager.fileExists(atPath: pristineURL($0).path) }
        let pendingBefore = index.pending.count
        index.installed.removeAll { missing.contains($0) }
        index.pending = pending(now: now)
        if !missing.isEmpty || index.pending.count != pendingBefore {
            try save()
        }
        return missing
    }

    // MARK: Importing

    /// Reads and checks a file that might be a disc image.
    public nonisolated static func candidate(at url: URL) throws -> DiskCandidate {
        let name = url.lastPathComponent
        guard let format = Disc.ImageFormat(path: url.path), importableFormats.contains(format) else {
            throw ImportError.unsupportedType(name)
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey])
        } catch {
            throw ImportError.unreadable(name, error.localizedDescription)
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.isAliasFile != true else {
            throw ImportError.notARegularFile(name)
        }
        guard Int64(values.fileSize ?? 0) <= maxImageSize else { throw ImportError.tooLarge(name) }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .uncached)
        } catch {
            throw ImportError.unreadable(name, error.localizedDescription)
        }
        guard Int64(data.count) <= maxImageSize else { throw ImportError.tooLarge(name) }
        // MacBeeb's own disc code decides whether it's a disc.
        let bytes = [UInt8](data)
        guard !data.isEmpty, (try? Disc.fromImage(bytes, format: format)) != nil,
              (try? DFSDisc.sides(ofImage: bytes, doubleSided: format == .dsd)) != nil else {
            throw ImportError.notADiscImage(name)
        }
        return DiskCandidate(url: url, digest: sha256(data), byteCount: Int64(data.count), format: format, data: data)
    }

    public nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The single way discs get into the library. With `gameID` nil the disc
    /// is identified by its digest, and an unknown disc comes back
    /// `.unrecognised`. With `gameID` (the user chose the game) an unknown
    /// disc is installed as that game, unverified; one the catalogue knows
    /// as another game is refused.
    public func importDisk(at url: URL, as gameID: String? = nil, source: ImportSource) throws -> ImportResult {
        try importCandidate(Self.candidate(at: url), as: gameID, source: source)
    }

    public func importCandidate(_ candidate: DiskCandidate, as gameID: String? = nil,
                                source: ImportSource) throws -> ImportResult {
        let match = catalogue.game(forDigest: candidate.digest)
        let game: CuratedGame
        if let gameID {
            guard let chosen = catalogue.game(id: gameID) else { throw ImportError.unknownGame(gameID) }
            if let match, match.id != chosen.id {
                throw ImportError.belongsToAnotherGame(fileName: candidate.fileName, game: match.title)
            }
            game = chosen
        } else {
            guard let match else { return .unrecognised(candidate) }
            game = match
        }

        if let existing = installed(gameID: game.id), existing.diskSHA256 == candidate.digest,
           (try? Self.sha256(Data(contentsOf: pristineURL(existing)))) == candidate.digest {
            index.pending.removeAll { $0.gameID == game.id }
            try save()
            return .installed(existing, alreadyInstalled: true)
        }

        let ext = candidate.format == .dsd ? "dsd" : "ssd"
        let fileName = "\(game.id)-\(candidate.digest.prefix(16)).\(ext)"
        let destination = gamesDirectory.appendingPathComponent(fileName)
        do {
            try fileManager.createDirectory(at: gamesDirectory, withIntermediateDirectories: true)
            try candidate.data.write(to: destination, options: .atomic)
        } catch {
            throw ImportError.libraryWriteFailed(error.localizedDescription)
        }
        // Check what landed, not what was read.
        guard (try? Self.sha256(Data(contentsOf: destination))) == candidate.digest else {
            try? fileManager.removeItem(at: destination)
            throw ImportError.verificationFailed(candidate.fileName)
        }

        let record = InstalledGame(libraryID: UUID(), gameID: game.id, fileName: fileName, diskSHA256: candidate.digest,
                                   byteCount: candidate.byteCount, importedAt: Date(), source: source,
                                   verified: match?.id == game.id)
        let replaced = installed(gameID: game.id)
        index.installed.removeAll { $0.gameID == game.id }
        index.installed.append(record)
        index.pending.removeAll { $0.gameID == game.id }
        index.removedDigests.removeAll { $0 == candidate.digest }
        do {
            try save()
        } catch {
            throw ImportError.libraryWriteFailed(error.localizedDescription)
        }
        if let replaced, replaced.fileName != fileName {
            try? fileManager.removeItem(at: pristineURL(replaced))
            try? fileManager.removeItem(at: workingURL(replaced))
        }
        return .installed(record, alreadyInstalled: false)
    }

    /// Takes a game out of the library: its copies only (never the
    /// original download). Its quick saves are kept.
    public func remove(gameID: String) throws {
        guard let game = installed(gameID: gameID) else { return }
        index.installed.removeAll { $0.gameID == gameID }
        if !index.removedDigests.contains(game.diskSHA256) {
            index.removedDigests.append(game.diskSHA256)
        }
        try save()
        try? fileManager.removeItem(at: pristineURL(game))
        try? fileManager.removeItem(at: workingURL(game))
    }

    // MARK: Playing

    /// The copy that's played, which the BBC's writes go to.
    public func workingURL(_ game: InstalledGame) -> URL {
        workingDirectory.appendingPathComponent("\(game.libraryID.uuidString).\((game.fileName as NSString).pathExtension)")
    }

    /// The working copy, made from the pristine copy if there isn't one.
    public func prepareWorkingCopy(_ game: InstalledGame) throws -> URL {
        let url = workingURL(game)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            try Data(contentsOf: pristineURL(game)).write(to: url, options: .atomic)
        }
        return url
    }

    /// Whether the BBC has changed the working copy.
    public func workingCopyIsModified(_ game: InstalledGame) -> Bool {
        guard let data = try? Data(contentsOf: workingURL(game)) else { return false }
        return Self.sha256(data) != game.diskSHA256
    }

    /// Puts the working copy back as it was downloaded.
    public func revertWorkingCopy(_ game: InstalledGame) throws {
        try? fileManager.removeItem(at: workingURL(game))
        _ = try prepareWorkingCopy(game)
    }

    /// The installed game whose working copy is at `url`, if any.
    public func installedGame(workingURL url: URL) -> InstalledGame? {
        let path = url.standardizedFileURL.path
        return index.installed.first { workingURL($0).standardizedFileURL.path == path }
    }

    private func save() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder.library.encode(index).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }
}

extension JSONEncoder {
    static var library: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var library: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
