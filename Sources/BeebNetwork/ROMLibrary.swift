import BeebCore
#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import Observation

/// How a ROM image goes into a machine.
public enum ROMLayout: Codable, Sendable, Hashable {
    /// 16K or less, in one bank. (A smaller image repeats to fill it, as
    /// an 8K chip does in a 16K socket.)
    case single
    /// 32K: two 16K ROMs in one chip, for a socket that takes two banks
    /// (the B+'s, the Master's IC37 and IC41, and cartridges): the first
    /// 16K in the lower bank, the second in the upper.
    case pair
    /// Bigger than 16K in one bank, switched by its mapper.
    case mapped(BBCMicro.ROMMapper)

    /// The layouts an image of `size` bytes could have, most likely first.
    /// A 32K image with two different ROMs in it is a pair; with the same
    /// ROM's title in both halves, it's switched (as Inter-Word is).
    public static func candidates(for image: [UInt8]) -> [ROMLayout] {
        if image.count <= 0x4000 { return [.single] }
        let mapped = BBCMicro.ROMMapper.candidates(forSize: image.count).map { ROMLayout.mapped($0) }
        guard image.count == 0x8000 else { return mapped }
        let low = BBCMicro.ROMHeader(Array(image[0..<0x100]))
        let high = BBCMicro.ROMHeader(Array(image[0x4000..<0x4100]))
        let pairFirst = low != nil && high != nil && low?.title != high?.title
        return pairFirst ? [.pair] + mapped : mapped + [.pair]
    }

    /// The banks it takes.
    public var banks: Int { self == .pair ? 2 : 1 }

    public var displayName: String {
        switch self {
        case .single: "16K"
        case .pair: "Two 16K ROMs (32K)"
        case .mapped(let mapper): mapper.displayName
        }
    }

    /// Whether an image of `size` bytes can be laid out like this.
    public func fits(size: Int) -> Bool {
        switch self {
        case .single: size > 0 && size <= 0x4000
        case .pair: size == 0x8000
        case .mapped(let mapper): size == mapper.size
        }
    }
}

/// A ROM the user has added: its image is kept in the ROM library (and a
/// network's copy in its package), named by its SHA-256.
public struct UserROM: Codable, Sendable, Hashable, Identifiable {
    /// The image's SHA-256, in hex.
    public var id: String
    /// What it's called: the user's name for it, from its file at first.
    public var name: String
    /// The file it came from.
    public var fileName: String
    public var size: Int
    public var layout: ROMLayout
    /// The (first) ROM header's title and version, and whether it's a
    /// language; nil when the image has no valid header.
    public var title: String?
    public var version: String?
    public var copyright: String?
    public var isLanguage: Bool
    public var added: Date

    /// A plugged-in reference to it.
    public var plugged: PluggedROM { PluggedROM(id: id, name: name, layout: layout) }

    /// "INTER-WORD 1.02 · Language · 32K".
    public var summary: String {
        var parts: [String] = []
        if let title { parts.append([title, version].compactMap { $0 }.joined(separator: " ")) }
        if title != nil { parts.append(isLanguage ? "Language" : "Service") }
        parts.append(size >= 1024 ? "\(size / 1024)K" : "\(size) bytes")
        return parts.joined(separator: " · ")
    }
}

/// Where ROM images are found, by their id: `<id>.rom` in each folder in
/// turn (a network's own copies, then the library).
public struct ROMSource: Sendable {
    public var folders: [URL]

    public init(folders: [URL]) {
        self.folders = folders
    }

    /// The user's ROM library.
    public static var library: ROMSource { ROMSource(folders: [ROMLibrary.defaultFolder]) }

    public static func fileName(for id: String) -> String { id + ".rom" }

    public func data(for id: String) -> [UInt8]? {
        for folder in folders {
            if let data = FileManager.default.contents(atPath: folder.appendingPathComponent(Self.fileName(for: id)).path) {
                return [UInt8](data)
            }
        }
        return nil
    }

    public func has(_ id: String) -> Bool {
        folders.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.fileName(for: id)).path) }
    }
}

/// The user's sideways ROMs: copies of the files they've added, in
/// Application Support/MacBeeb/ROMs, with an index of names and layouts.
@Observable
public final class ROMLibrary: @unchecked Sendable {
    public static let shared = ROMLibrary(folder: defaultFolder)

    /// Application Support/MacBeeb/ROMs, unless the MacBeebROMLibraryFolder
    /// default says otherwise (self-tests use their own).
    public static var defaultFolder: URL {
        if let folder = UserDefaults.standard.string(forKey: "MacBeebROMLibraryFolder") {
            return URL(fileURLWithPath: folder, isDirectory: true)
        }
        return URL.applicationSupportDirectory.appendingPathComponent("MacBeeb/ROMs", isDirectory: true)
    }

    public let folder: URL
    /// By name.
    public private(set) var roms: [UserROM] = []

    public enum AddError: Error, CustomStringConvertible, Equatable {
        case empty(String)
        case tooBig(String, Int)
        case unknownSize(String, Int)

        public var description: String {
            switch self {
            case .empty(let name): "\(name) is empty."
            case .tooBig(let name, let size): "\(name) is \(size / 1024)K: sideways ROMs are at most 128K."
            case .unknownSize(let name, let size):
                "\(name) is \(size) bytes. A sideways ROM is up to 16K, or 32K, 64K or 128K with its own switching."
            }
        }
    }

    public init(folder: URL) {
        self.folder = folder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        roms = (try? decoder.decode([UserROM].self, from: Data(contentsOf: indexURL))) ?? []
        sort()
    }

    private var indexURL: URL { folder.appendingPathComponent("Index.json") }

    public var source: ROMSource { ROMSource(folders: [folder]) }

    public subscript(id: String) -> UserROM? { roms.first { $0.id == id } }

    /// Adds the image in `url` (or finds it, if it's here already).
    @discardableResult
    public func add(fileAt url: URL) throws -> UserROM {
        let name = url.lastPathComponent
        let image = [UInt8](try Data(contentsOf: url))
        guard !image.isEmpty else { throw AddError.empty(name) }
        guard image.count <= 0x20000 else { throw AddError.tooBig(name, image.count) }
        guard let layout = ROMLayout.candidates(for: image).first else { throw AddError.unknownSize(name, image.count) }
        let id = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        if let existing = self[id] { return existing }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(image).write(to: folder.appendingPathComponent(ROMSource.fileName(for: id)), options: .atomic)
        let header = BBCMicro.ROMHeader(Array(image.prefix(0x100)))
        let rom = UserROM(id: id, name: url.deletingPathExtension().lastPathComponent, fileName: name, size: image.count,
                          layout: layout, title: header?.title, version: header?.version, copyright: header?.copyright,
                          isLanguage: header?.isLanguage ?? false, added: Date())
        roms.append(rom)
        sort()
        try save()
        return rom
    }

    /// Changes a ROM's name or layout.
    public func update(_ rom: UserROM) throws {
        guard let index = roms.firstIndex(where: { $0.id == rom.id }) else { return }
        roms[index] = rom
        sort()
        try save()
    }

    /// Takes a ROM out of the library. (Machines that use it keep its
    /// place, and say it's missing.)
    public func remove(_ id: String) throws {
        roms.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(ROMSource.fileName(for: id)))
        try save()
    }

    public func data(for id: String) -> [UInt8]? { source.data(for: id) }

    private func sort() {
        roms.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(roms).write(to: indexURL, options: .atomic)
    }
}
