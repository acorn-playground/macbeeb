#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A disc's files, as its filing system keeps them: DFS (one side, or
/// two, which the BBC calls drives 0 and 2) or ADFS.
public enum DiscVolume: Sendable {
    case dfs([DFSDisc])
    case adfs(ADFSDisc)

    public enum ReadError: Error, Equatable, LocalizedError {
        /// Neither DFS nor ADFS (a DOS disc, or unformatted).
        case unrecognised
        /// Holds sectors a disc image can't, so changing it would lose them.
        case protected

        public var errorDescription: String? {
            switch self {
            case .unrecognised: "The disc isn’t formatted for DFS or ADFS."
            case .protected: "The disc has copy protection, which changing its files here would lose."
            }
        }
    }

    /// What the disc holds, read from its sectors.
    public init(disc: Disc) throws(ReadError) {
        if let adfs = try? ADFSDisc(image: disc.toADFS(doubleSided: disc.isDoubleSided)) {
            self = .adfs(adfs)
            return
        }
        guard disc.ssdShortfalls().isEmpty else {
            // Protected, or not FM at all (DOS discs, say).
            throw disc.tracksUsed > 0 && (try? disc.toSSDOrDSD(force: true)).flatMap { try? DFSDisc(side: $0) } != nil
                ? .protected : .unrecognised
        }
        guard let image = try? disc.toSSDOrDSD(),
              let sides = try? DFSDisc.sides(ofImage: image, doubleSided: disc.isDoubleSided),
              let first = sides.first, first.sectorCount > 2 else { throw .unrecognised }
        self = .dfs(sides)
    }

    /// The image file format that holds it.
    public var format: Disc.ImageFormat {
        switch self {
        case .dfs(let sides): sides.count == 2 ? .dsd : .ssd
        case .adfs(let disc): disc.totalSectors > 80 * 16 ? .adl : .adf
        }
    }

    public var image: [UInt8] {
        switch self {
        case .dfs(let sides): DFSDisc.image(sides: sides)
        case .adfs(let disc): disc.image
        }
    }
}

// MARK: Files, for both filing systems

extension DiscVolume {
    /// Where files are: a DFS side (0, or 1 for the BBC's drive 2/3), or an
    /// ADFS directory (by sector; the root is 2).
    public struct Location: Sendable, Hashable {
        public var side: Int
        public var directory: Int

        public init(side: Int = 0, directory: Int = ADFSDisc.rootSector) {
            self.side = side
            self.directory = directory
        }
    }

    /// A file, or an ADFS directory.
    public struct Item: Sendable, Hashable, Identifiable {
        /// The name as *CAT shows it: DFS's with its directory unless that's
        /// "$" ("ELITE", "W.DATA").
        public var name: String
        /// DFS's "$.ELITE"; ADFS's name.
        public var fullName: String
        public var loadAddress: UInt32
        public var executionAddress: UInt32
        public var length: Int
        public var locked: Bool
        public var isDirectory: Bool
        /// ADFS's access letters ("WR", "DLR"); DFS's "L" if locked.
        public var access: String
        public var startSector: Int

        public var id: String { fullName.uppercased() }
    }

    public var isADFS: Bool {
        if case .adfs = self { true } else { false }
    }

    public var sideCount: Int {
        if case .dfs(let sides) = self { sides.count } else { 1 }
    }

    public func items(at location: Location) throws(DiscEditError) -> [Item] {
        switch self {
        case .dfs(let sides):
            guard location.side < sides.count else { return [] }
            return sides[location.side].files.map { file in
                Item(name: file.directory == "$" ? file.name : file.fullName, fullName: file.fullName,
                     loadAddress: file.loadAddress, executionAddress: file.executionAddress, length: file.length,
                     locked: file.locked, isDirectory: false, access: file.locked ? "L" : "",
                     startSector: file.startSector)
            }
        case .adfs(let disc):
            return try disc.directory(at: location.directory).entries.map { entry in
                // *CAT's order: D L E W R.
                let access = [("D", ADFSDisc.Attribute.directory), ("L", ADFSDisc.Attribute.locked),
                              ("E", ADFSDisc.Attribute.executeOnly), ("W", ADFSDisc.Attribute.write),
                              ("R", ADFSDisc.Attribute.read)]
                    .filter { entry.attributes & $0.1 != 0 }.map(\.0).joined()
                return Item(name: entry.name, fullName: entry.name, loadAddress: entry.loadAddress,
                            executionAddress: entry.executionAddress, length: entry.length, locked: entry.locked,
                            isDirectory: entry.isDirectory, access: access, startSector: entry.startSector)
            }
        }
    }

    public func contents(of item: Item, at location: Location) -> [UInt8] {
        switch self {
        case .dfs(let sides):
            guard location.side < sides.count, let file = sides[location.side].file(named: item.fullName) else { return [] }
            return sides[location.side].contents(of: file)
        case .adfs(let disc):
            guard let entry = try? disc.directory(at: location.directory).entries.first(where: { $0.id == item.id })
            else { return [] }
            return disc.contents(of: entry)
        }
    }

    /// The title: the DFS side's, or the ADFS root directory's.
    public func title(side: Int = 0) -> String {
        switch self {
        case .dfs(let sides): side < sides.count ? sides[side].title : ""
        case .adfs(let disc): disc.title
        }
    }

    public func bootOption(side: Int = 0) -> Int {
        switch self {
        case .dfs(let sides): side < sides.count ? sides[side].bootOption : 0
        case .adfs(let disc): disc.bootOption
        }
    }

    public func freeSectors(side: Int = 0) -> Int {
        switch self {
        case .dfs(let sides): side < sides.count ? sides[side].freeSectors : 0
        case .adfs(let disc): disc.freeSectors
        }
    }

    public var maxNameLength: Int { isADFS ? ADFSDisc.maxNameLength : DFSDisc.maxNameLength }
    public var maxTitleLength: Int { isADFS ? ADFSDisc.maxTitleLength : 12 }

    public mutating func setTitle(_ title: String, side: Int = 0) {
        let title = String(title.prefix(maxTitleLength))
        switch self {
        case .dfs(var sides):
            guard side < sides.count else { return }
            sides[side].title = title
            self = .dfs(sides)
        case .adfs(var disc):
            disc.title = title
            self = .adfs(disc)
        }
    }

    public mutating func setBootOption(_ option: Int, side: Int = 0) {
        switch self {
        case .dfs(var sides):
            guard side < sides.count else { return }
            sides[side].bootOption = option
            self = .dfs(sides)
        case .adfs(var disc):
            disc.bootOption = option
            self = .adfs(disc)
        }
    }

    /// Splits a DFS name into its directory ("$" if none) and name.
    public static func dfsNameParts(_ name: String) -> (Character, String) {
        let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].count == 1 {
            return (parts[0].first!, String(parts[1]))
        }
        return ("$", name)
    }

    /// Saves a file (DFS names may have a directory: "W.DATA").
    public mutating func save(at location: Location, name: String, loadAddress: UInt32, executionAddress: UInt32,
                              contents: [UInt8], locked: Bool = false) throws(DiscEditError) {
        switch self {
        case .dfs(var sides):
            guard location.side < sides.count else { throw .notFormatted }
            let (directory, leaf) = Self.dfsNameParts(name)
            try sides[location.side].save(directory: directory, name: leaf, loadAddress: loadAddress,
                                          executionAddress: executionAddress, contents: contents, locked: locked)
            self = .dfs(sides)
        case .adfs(var disc):
            try disc.save(in: location.directory, name: name, loadAddress: loadAddress,
                          executionAddress: executionAddress, contents: contents, locked: locked)
            self = .adfs(disc)
        }
    }

    public mutating func createDirectory(at location: Location, name: String) throws(DiscEditError) {
        guard case .adfs(var disc) = self else { throw .badName(name) }
        try disc.createDirectory(in: location.directory, name: name)
        self = .adfs(disc)
    }

    public mutating func delete(_ item: Item, at location: Location) throws(DiscEditError) {
        switch self {
        case .dfs(var sides):
            guard location.side < sides.count, let file = sides[location.side].file(named: item.fullName) else {
                throw .notFound(item.name)
            }
            try sides[location.side].delete(file)
            self = .dfs(sides)
        case .adfs(var disc):
            guard let entry = try disc.directory(at: location.directory).entries.first(where: { $0.id == item.id }) else {
                throw .notFound(item.name)
            }
            try disc.delete(entry, in: location.directory)
            self = .adfs(disc)
        }
    }

    /// Renames an item (a DFS name without a directory goes in "$").
    public mutating func rename(_ item: Item, at location: Location, to name: String) throws(DiscEditError) {
        switch self {
        case .dfs(var sides):
            guard location.side < sides.count, let file = sides[location.side].file(named: item.fullName) else {
                throw .notFound(item.name)
            }
            let (directory, leaf) = Self.dfsNameParts(name)
            try sides[location.side].rename(file, directory: directory, name: leaf)
            self = .dfs(sides)
        case .adfs(var disc):
            guard let entry = try disc.directory(at: location.directory).entries.first(where: { $0.id == item.id }) else {
                throw .notFound(item.name)
            }
            try disc.rename(entry, in: location.directory, to: name)
            self = .adfs(disc)
        }
    }

    public mutating func update(_ item: Item, at location: Location, loadAddress: UInt32, executionAddress: UInt32,
                                locked: Bool) throws(DiscEditError) {
        switch self {
        case .dfs(var sides):
            guard location.side < sides.count, let file = sides[location.side].file(named: item.fullName) else {
                throw .notFound(item.name)
            }
            try sides[location.side].update(file, loadAddress: loadAddress, executionAddress: executionAddress,
                                            locked: locked)
            self = .dfs(sides)
        case .adfs(var disc):
            guard let entry = try disc.directory(at: location.directory).entries.first(where: { $0.id == item.id }) else {
                throw .notFound(item.name)
            }
            try disc.update(entry, in: location.directory, loadAddress: loadAddress, executionAddress: executionAddress,
                            locked: locked)
            self = .adfs(disc)
        }
    }
}
