import BeebCore
import Foundation
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

/// A game the user added to the bookshelf themselves: a disc image, a
/// cover, or both, and how to play it.
public struct PersonalGame: Codable, Sendable, Identifiable, Equatable, Hashable {
    /// Also the disc's identity for quick saves.
    public var id: UUID
    public var title: String
    public var publisher: String?
    public var year: Int?
    public var notes: String?
    public var model: BBCMicro.Model
    public var coprocessor: BBCMicro.Coprocessor?
    public var start: StartMethod
    /// In the game's folder.
    public var discFile: String?
    public var discSHA256: String?
    public var coverFile: String?
    public var added: Date

    public init(id: UUID = UUID(), title: String, publisher: String? = nil, year: Int? = nil, notes: String? = nil,
                model: BBCMicro.Model = .modelB, coprocessor: BBCMicro.Coprocessor? = nil, start: StartMethod = .boot,
                added: Date = Date()) {
        self.id = id
        self.title = title
        self.publisher = publisher
        self.year = year
        self.notes = notes
        self.model = model
        self.coprocessor = coprocessor
        self.start = start
        self.added = added
    }

    /// "BBC Master 128 with a 6502 Second Processor".
    public var machineSummary: String {
        model.displayName + (coprocessor.map { " with a \($0.displayName)" } ?? "")
    }
}

/// How a game's started once its disc is in.
public enum StartMethod: Codable, Sendable, Equatable, Hashable {
    /// Shift-Break, as the disc's !BOOT has it.
    case boot
    /// Types a command at the prompt, e.g. CHAIN "GAME".
    case type(String)
    /// Puts the disc in and leaves the rest to the user.
    case insertOnly
}

public enum MyGamesError: LocalizedError, Equatable {
    case notADisc(String)
    case notAnImage(String)
    case tooLarge(String)
    case unreadable(String, String)
    case notFound
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notADisc(let name): "“\(name)” isn’t a disc image MacBeeb can read."
        case .notAnImage(let name): "“\(name)” isn’t a picture MacBeeb can show."
        case .tooLarge(let name): "“\(name)” is too large."
        case .unreadable(let name, let why): "“\(name)” can’t be read: \(why)"
        case .notFound: "The game isn’t in My Games any more."
        case .writeFailed(let why): "MacBeeb couldn’t save the game: \(why)"
        }
    }
}

/// A disc image the user's adding, read and checked.
public struct DiscFile: Sendable, Equatable {
    public var url: URL
    public var data: Data
    public var format: Disc.ImageFormat
    public var digest: String

    public var fileName: String { url.lastPathComponent }

    /// A title from the file's name: "Disc040-Exile_Enhanced.ssd" is
    /// "Exile Enhanced".
    public var suggestedTitle: String {
        var name = url.deletingPathExtension().lastPathComponent
        // The archive's "Disc040-" prefix.
        if let range = name.range(of: #"^Disc\d+-"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        name = name.replacingOccurrences(of: "_", with: " ")
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// The machine a disc of this format is likeliest to want: ADFS discs
    /// a Master, DOS discs the Master 512.
    public var suggestedMachine: (BBCMicro.Model, BBCMicro.Coprocessor?) {
        switch format {
        case .ssd, .dsd: (.modelB, nil)
        case .adf, .adl: (.master128, nil)
        case .img, .dos: (.master128, .master512)
        }
    }

    /// Boot it if its boot option says to, otherwise just put it in.
    public var suggestedStart: StartMethod {
        guard format == .ssd || format == .dsd,
              let side = try? DFSDisc.sides(ofImage: [UInt8](data), doubleSided: format == .dsd).first else { return .boot }
        return side.bootOption == 0 ? .insertOnly : .boot
    }
}

/// The user's own games, in Application Support/MacBeeb/Library/MyGames:
///
///     mygames.json         the index
///     <id>/disc.ssd        the game's disc (played and written to)
///     <id>/cover-….jpg     its cover
///
/// Files are copied in; the originals are only read.
public actor MyGames {
    public nonisolated let root: URL
    private var index: Index
    private let fileManager = FileManager.default

    public static let maxDiscSize: Int64 = 1 << 20
    public static let maxCoverSize: Int64 = 32 << 20
    public static let coverExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "tif", "tiff", "webp", "bmp"]

    struct Index: Codable {
        var version = 1
        var games: [PersonalGame] = []
    }

    public init(root: URL) {
        self.root = root
        index = (try? JSONDecoder.library.decode(Index.self, from: Data(contentsOf: root.appendingPathComponent("mygames.json"))))
            ?? Index()
    }

    public static var defaultRoot: URL {
        GameLibrary.defaultRoot.appendingPathComponent("MyGames", isDirectory: true)
    }

    /// In the order they were added.
    public var games: [PersonalGame] { index.games }

    public func game(id: UUID) -> PersonalGame? {
        index.games.first { $0.id == id }
    }

    private func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public nonisolated func discURL(_ game: PersonalGame) -> URL? {
        game.discFile.map { root.appendingPathComponent(game.id.uuidString).appendingPathComponent($0) }
    }

    public nonisolated func coverURL(_ game: PersonalGame) -> URL? {
        game.coverFile.map { root.appendingPathComponent(game.id.uuidString).appendingPathComponent($0) }
    }

    // MARK: Checking files

    public nonisolated static func isDiscName(_ url: URL) -> Bool {
        Disc.ImageFormat(path: url.path) != nil
    }

    public nonisolated static func isCoverName(_ url: URL) -> Bool {
        coverExtensions.contains(url.pathExtension.lowercased())
    }

    /// Reads a disc image of any format MacBeeb plays.
    public nonisolated static func readDisc(at url: URL) throws -> DiscFile {
        let name = url.lastPathComponent
        guard let format = Disc.ImageFormat(path: url.path) else { throw MyGamesError.notADisc(name) }
        let data = try read(url, limit: maxDiscSize)
        guard (try? Disc.fromImage([UInt8](data), format: format)) != nil else { throw MyGamesError.notADisc(name) }
        return DiscFile(url: url, data: data, format: format, digest: GameLibrary.sha256(data))
    }

    /// Checks a picture can be shown.
    public nonisolated static func checkCover(at url: URL) throws -> Data {
        let name = url.lastPathComponent
        guard isCoverName(url) else { throw MyGamesError.notAnImage(name) }
        let data = try read(url, limit: maxCoverSize)
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw MyGamesError.notAnImage(name)
        }
        #else
        guard coverDecodes(data) else { throw MyGamesError.notAnImage(name) }
        #endif
        return data
    }

    #if !canImport(ImageIO)
    /// Whether a picture can be shown, where there's no ImageIO (Linux):
    /// the app decodes it with GDK; without the app, it's whether it looks
    /// like one of the cover formats.
    public nonisolated(unsafe) static var coverDecodes: @Sendable (Data) -> Bool = looksLikeCover

    /// Whether `data` starts as a cover format's files do.
    public nonisolated static func looksLikeCover(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        return starts([0x89, 0x50, 0x4E, 0x47]) // PNG
            || starts([0xFF, 0xD8, 0xFF]) // JPEG
            || starts(Array("GIF8".utf8))
            || starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) // TIFF
            || (starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8))
            || starts(Array("BM".utf8))
            || starts(Array("ftyp".utf8), at: 4) // HEIC
    }
    #endif

    private nonisolated static func read(_ url: URL, limit: Int64) throws -> Data {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw MyGamesError.unreadable(name, "it isn’t a file.") }
        guard Int64(values?.fileSize ?? 0) <= limit else { throw MyGamesError.tooLarge(name) }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw MyGamesError.unreadable(name, error.localizedDescription)
        }
    }

    /// Groups dropped files into games: each disc image is a game, with the
    /// picture of the same name (elite.ssd and elite.jpg) as its cover, or
    /// the only picture if there's one disc and one picture. Pictures left
    /// over are games without discs, for now.
    public nonisolated static func group(_ urls: [URL]) -> [(disc: URL?, cover: URL?)] {
        let discs = urls.filter(isDiscName)
        var covers = urls.filter(isCoverName)
        if discs.count == 1 && covers.count == 1 {
            return [(discs[0], covers[0])]
        }
        func stem(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.lowercased() }
        var result: [(disc: URL?, cover: URL?)] = []
        for disc in discs {
            let cover = covers.firstIndex { stem($0) == stem(disc) }.map { covers.remove(at: $0) }
            result.append((disc, cover))
        }
        result += covers.map { (nil, $0) }
        return result
    }

    // MARK: Changing

    /// Adds a game, copying in its disc and cover (either may come later).
    @discardableResult
    public func add(_ game: PersonalGame, disc: DiscFile?, cover: URL?) throws -> PersonalGame {
        var game = game
        do {
            try fileManager.createDirectory(at: folder(game.id), withIntermediateDirectories: true)
            if let disc { try copyDisc(disc, into: &game) }
            if let cover { try copyCover(cover, into: &game) }
        } catch let error as MyGamesError {
            try? fileManager.removeItem(at: folder(game.id))
            throw error
        } catch {
            try? fileManager.removeItem(at: folder(game.id))
            throw MyGamesError.writeFailed(error.localizedDescription)
        }
        index.games.removeAll { $0.id == game.id }
        index.games.append(game)
        try save()
        return game
    }

    /// Changes a game's details (not its files).
    public func update(_ changed: PersonalGame) throws {
        guard let i = index.games.firstIndex(where: { $0.id == changed.id }) else { throw MyGamesError.notFound }
        var game = changed
        game.discFile = index.games[i].discFile
        game.discSHA256 = index.games[i].discSHA256
        game.coverFile = index.games[i].coverFile
        index.games[i] = game
        try save()
    }

    /// Gives a game a disc, or a new one.
    @discardableResult
    public func setDisc(_ disc: DiscFile, for id: UUID) throws -> PersonalGame {
        guard let i = index.games.firstIndex(where: { $0.id == id }) else { throw MyGamesError.notFound }
        var game = index.games[i]
        let old = discURL(game)
        do {
            try copyDisc(disc, into: &game)
        } catch let error as MyGamesError {
            throw error
        } catch {
            throw MyGamesError.writeFailed(error.localizedDescription)
        }
        if let old, old != discURL(game) { try? fileManager.removeItem(at: old) }
        index.games[i] = game
        try save()
        return game
    }

    /// Gives a game a cover, or a new one.
    @discardableResult
    public func setCover(_ url: URL, for id: UUID) throws -> PersonalGame {
        guard let i = index.games.firstIndex(where: { $0.id == id }) else { throw MyGamesError.notFound }
        var game = index.games[i]
        let old = coverURL(game)
        do {
            try copyCover(url, into: &game)
        } catch let error as MyGamesError {
            throw error
        } catch {
            throw MyGamesError.writeFailed(error.localizedDescription)
        }
        if let old, old != coverURL(game) { try? fileManager.removeItem(at: old) }
        index.games[i] = game
        try save()
        return game
    }

    /// Deletes a game and MacBeeb's copies of its files (never the
    /// originals). Its quick saves are kept.
    public func remove(id: UUID) throws {
        index.games.removeAll { $0.id == id }
        try save()
        try? fileManager.removeItem(at: folder(id))
    }

    /// Forgets files that have gone from the game's folder.
    public func reconcile() throws {
        var changed = false
        for i in index.games.indices {
            if let url = discURL(index.games[i]), !fileManager.fileExists(atPath: url.path) {
                index.games[i].discFile = nil
                index.games[i].discSHA256 = nil
                changed = true
            }
            if let url = coverURL(index.games[i]), !fileManager.fileExists(atPath: url.path) {
                index.games[i].coverFile = nil
                changed = true
            }
        }
        if changed { try save() }
    }

    private func copyDisc(_ disc: DiscFile, into game: inout PersonalGame) throws {
        let name = "disc.\(disc.url.pathExtension.lowercased())"
        let url = folder(game.id).appendingPathComponent(name)
        try fileManager.createDirectory(at: folder(game.id), withIntermediateDirectories: true)
        try disc.data.write(to: url, options: .atomic)
        guard (try? GameLibrary.sha256(Data(contentsOf: url))) == disc.digest else {
            throw MyGamesError.writeFailed("the copy of “\(disc.fileName)” didn’t match the original.")
        }
        game.discFile = name
        game.discSHA256 = disc.digest
    }

    private func copyCover(_ source: URL, into game: inout PersonalGame) throws {
        let data = try Self.checkCover(at: source)
        // A new name each time, so nothing shows a cached old cover.
        let name = "cover-\(UUID().uuidString.prefix(8)).\(source.pathExtension.lowercased())"
        try fileManager.createDirectory(at: folder(game.id), withIntermediateDirectories: true)
        try data.write(to: folder(game.id).appendingPathComponent(name), options: .atomic)
        game.coverFile = name
    }

    private func save() throws {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder.library.encode(index).write(to: root.appendingPathComponent("mygames.json"), options: .atomic)
        } catch {
            throw MyGamesError.writeFailed(error.localizedDescription)
        }
    }
}
