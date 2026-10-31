#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// An ADFS disc (S, M or L, the old map): the free space map in sectors 0
/// and 1, and "Hugo" directories from the root at sector 2. Read, and
/// changed from outside the BBC as ADFS itself would change it.
///
/// `data` is the disc's logical sectors in order, which is how .adf and
/// .adl images hold them.
public struct ADFSDisc: Sendable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var name: String
        public var loadAddress: UInt32
        public var executionAddress: UInt32
        public var length: Int
        public var startSector: Int
        /// The access bits, R W L D E from bit 0 up, as the top bits of the
        /// name's first five characters hold them.
        public var attributes: UInt8
        public var sequence: UInt8

        public var id: String { name.uppercased() }
        public var isDirectory: Bool { attributes & Attribute.directory != 0 }
        public var locked: Bool { attributes & Attribute.locked != 0 }
    }

    public enum Attribute {
        public static let read: UInt8 = 1
        public static let write: UInt8 = 2
        public static let locked: UInt8 = 4
        public static let directory: UInt8 = 8
        public static let executeOnly: UInt8 = 16
        /// What SAVE gives a file: WR.
        public static let file: UInt8 = read | write
        /// What *CDIR gives a directory: DLR.
        public static let newDirectory: UInt8 = directory | locked | read
    }

    public struct Directory: Sendable {
        public var sector: Int
        public var name: String
        public var title: String
        public var parent: Int
        public var sequence: UInt8
        public var entries: [Entry]
    }

    public enum Error: Swift.Error {
        case notADFS
    }

    public static let sectorSize = 256
    public static let rootSector = 2
    static let directorySectors = 5
    static let directorySize = directorySectors * sectorSize
    public static let maxEntries = 47
    public static let maxNameLength = 10
    public static let maxTitleLength = 19
    static let maxFreeSpaces = 82

    public internal(set) var data: [UInt8]
    public let totalSectors: Int
    /// The free spaces, by start sector.
    var free: [(start: Int, length: Int)]

    public init(image: [UInt8]) throws {
        guard image.count >= 7 * Self.sectorSize,
              ADFSMap.checksum(image[0..<0xFF]) == image[0xFF],
              ADFSMap.checksum(image[0x100..<0x1FF]) == image[0x1FF],
              image[0x201..<0x205].elementsEqual("Hugo".utf8) else { throw Error.notADFS }
        func get24(_ offset: Int) -> Int {
            Int(image[offset]) | Int(image[offset + 1]) << 8 | Int(image[offset + 2]) << 16
        }
        totalSectors = get24(0xFC)
        let count = min(Int(image[0x1FE]) / 3, Self.maxFreeSpaces)
        free = (0..<count).map { (get24($0 * 3), get24(0x100 + $0 * 3)) }
        data = image
        let size = totalSectors * Self.sectorSize
        if data.count < size {
            data += [UInt8](repeating: 0, count: size - data.count)
        }
    }

    public var freeSectors: Int { free.reduce(0) { $0 + $1.length } }

    /// *OPT 4: 0 none, 1 *LOAD, 2 *RUN, 3 *EXEC !BOOT.
    public var bootOption: Int {
        get { Int(data[0x1FD] & 3) }
        set {
            data[0x1FD] = UInt8(newValue & 3)
            writeMap()
        }
    }

    /// The root directory's title, which *CAT shows as the disc's.
    public var title: String {
        get { (try? directory(at: Self.rootSector).title) ?? "" }
        set {
            let base = Self.rootSector * Self.sectorSize
            putText(newValue, at: base + 0x4D9, length: Self.maxTitleLength)
            countSequence(base)
        }
    }

    // MARK: Reading

    public func directory(at sector: Int) throws(DiscEditError) -> Directory {
        let base = sector * Self.sectorSize
        guard sector >= Self.rootSector, base + Self.directorySize <= data.count,
              data[base + 1..<base + 5].elementsEqual("Hugo".utf8) else { throw .notFormatted }
        var entries: [Entry] = []
        for i in 0..<Self.maxEntries {
            let e = base + 5 + i * 26
            guard data[e] != 0 else { break }
            var attributes: UInt8 = 0
            for bit in 0..<5 where data[e + bit] & 0x80 != 0 {
                attributes |= 1 << bit
            }
            entries.append(Entry(name: text(at: e, length: Self.maxNameLength),
                                 loadAddress: get32(e + 10), executionAddress: get32(e + 14),
                                 length: Int(get32(e + 18)), startSector: get24(e + 22),
                                 attributes: attributes, sequence: data[e + 25]))
        }
        return Directory(sector: sector, name: text(at: base + 0x4CC, length: Self.maxNameLength),
                         title: text(at: base + 0x4D9, length: Self.maxTitleLength),
                         parent: get24(base + 0x4D6), sequence: data[base], entries: entries)
    }

    public func contents(of entry: Entry) -> [UInt8] {
        let start = entry.startSector * Self.sectorSize
        let end = min(start + entry.length, data.count)
        return start < end ? Array(data[start..<end]) : []
    }

    /// Whether ADFS accepts `name` for a file or directory.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= maxNameLength && name.unicodeScalars.allSatisfy {
            $0.value > 0x20 && $0.value < 0x7F && !" .:*#$&@^%\\|\"".unicodeScalars.contains($0)
        }
    }

    // MARK: Changing

    /// Saves a file in the directory at `directorySector`, replacing an
    /// unlocked file of the same name.
    public mutating func save(in directorySector: Int, name: String, loadAddress: UInt32, executionAddress: UInt32,
                              contents: [UInt8], locked: Bool = false) throws(DiscEditError) {
        guard Self.isValidName(name) else { throw .badName(name) }
        var disc = self
        var dir = try disc.directory(at: directorySector)
        if let existing = dir.entries.firstIndex(where: { $0.id == name.uppercased() }) {
            let old = dir.entries[existing]
            guard !old.isDirectory else { throw .fileExists(name) }
            guard !old.locked else { throw .locked(name) }
            try disc.release(old)
            dir.entries.remove(at: existing)
        }
        guard dir.entries.count < Self.maxEntries else { throw .catalogueFull }
        let start = try disc.allocate(Self.sectors(contents.count))
        disc.data.replaceSubrange(start * Self.sectorSize..<start * Self.sectorSize + contents.count, with: contents)
        dir.entries.append(Entry(name: name, loadAddress: loadAddress, executionAddress: executionAddress,
                                 length: contents.count, startSector: start,
                                 attributes: Attribute.file | (locked ? Attribute.locked : 0), sequence: 0))
        disc.write(dir)
        self = disc
    }

    /// Makes an empty directory, as *CDIR does.
    public mutating func createDirectory(in directorySector: Int, name: String) throws(DiscEditError) {
        guard Self.isValidName(name) else { throw .badName(name) }
        var disc = self
        var dir = try disc.directory(at: directorySector)
        guard !dir.entries.contains(where: { $0.id == name.uppercased() }) else { throw .fileExists(name) }
        guard dir.entries.count < Self.maxEntries else { throw .catalogueFull }
        let start = try disc.allocate(Self.directorySectors)
        let base = start * Self.sectorSize
        disc.data.replaceSubrange(base..<base + Self.directorySize, with: [UInt8](repeating: 0, count: Self.directorySize))
        disc.data.replaceSubrange(base + 1..<base + 5, with: Array("Hugo".utf8))
        disc.data.replaceSubrange(base + 0x4FB..<base + 0x4FF, with: Array("Hugo".utf8))
        disc.putText(name, at: base + 0x4CC, length: Self.maxNameLength)
        disc.putText(name, at: base + 0x4D9, length: Self.maxTitleLength)
        disc.put24(directorySector, at: base + 0x4D6)
        dir.entries.append(Entry(name: name, loadAddress: 0, executionAddress: 0, length: Self.directorySize,
                                 startSector: start, attributes: Attribute.newDirectory, sequence: 0))
        disc.write(dir)
        self = disc
    }

    /// Deletes a file, or an empty directory.
    public mutating func delete(_ entry: Entry, in directorySector: Int) throws(DiscEditError) {
        var disc = self
        var dir = try disc.directory(at: directorySector)
        guard let i = dir.entries.firstIndex(where: { $0.id == entry.id }) else { throw .notFound(entry.name) }
        let found = dir.entries[i]
        guard !found.locked else { throw .locked(found.name) }
        if found.isDirectory, try !disc.directory(at: found.startSector).entries.isEmpty {
            throw .directoryNotEmpty(found.name)
        }
        try disc.release(found)
        dir.entries.remove(at: i)
        disc.write(dir)
        self = disc
    }

    public mutating func rename(_ entry: Entry, in directorySector: Int, to name: String) throws(DiscEditError) {
        guard Self.isValidName(name) else { throw .badName(name) }
        var dir = try directory(at: directorySector)
        guard let i = dir.entries.firstIndex(where: { $0.id == entry.id }) else { throw .notFound(entry.name) }
        if dir.entries.contains(where: { $0.id == name.uppercased() && $0.id != entry.id }) {
            throw .fileExists(name)
        }
        dir.entries[i].name = name
        if dir.entries[i].isDirectory {
            putText(name, at: dir.entries[i].startSector * Self.sectorSize + 0x4CC, length: Self.maxNameLength)
        }
        write(dir)
    }

    /// Changes a file's addresses and lock.
    public mutating func update(_ entry: Entry, in directorySector: Int, loadAddress: UInt32,
                                executionAddress: UInt32, locked: Bool) throws(DiscEditError) {
        var dir = try directory(at: directorySector)
        guard let i = dir.entries.firstIndex(where: { $0.id == entry.id }) else { throw .notFound(entry.name) }
        if !dir.entries[i].isDirectory {
            dir.entries[i].loadAddress = loadAddress
            dir.entries[i].executionAddress = executionAddress
        }
        dir.entries[i].attributes = dir.entries[i].attributes & ~Attribute.locked | (locked ? Attribute.locked : 0)
        write(dir)
    }

    /// A new disc ID, as a different disc would have: ADFS checks it to
    /// know the disc's been changed, and reads the map again.
    public mutating func changeDiscID() {
        var id = UInt16(data[0x1FB]) | UInt16(data[0x1FC]) << 8
        id &+= UInt16.random(in: 1...0xFFFF)
        data[0x1FB] = UInt8(id & 0xFF)
        data[0x1FC] = UInt8(id >> 8)
        writeMap()
    }

    /// The disc as an image of `totalSectors`.
    public var image: [UInt8] { Array(data.prefix(totalSectors * Self.sectorSize)) }

    // MARK: Free space

    static func sectors(_ length: Int) -> Int { (length + sectorSize - 1) / sectorSize }

    /// Takes `count` sectors from the first free space big enough.
    private mutating func allocate(_ count: Int) throws(DiscEditError) -> Int {
        guard count > 0 else { return free.first?.start ?? totalSectors }
        guard let i = free.firstIndex(where: { $0.length >= count }) else { throw .discFull }
        let start = free[i].start
        if free[i].length == count {
            free.remove(at: i)
        } else {
            free[i] = (start + count, free[i].length - count)
        }
        writeMap()
        return start
    }

    /// Gives an entry's sectors back, joining them to free spaces either side.
    private mutating func release(_ entry: Entry) throws(DiscEditError) {
        let count = Self.sectors(entry.length)
        guard count > 0 else { return }
        var spaces = free + [(entry.startSector, count)]
        spaces.sort { $0.start < $1.start }
        var merged: [(start: Int, length: Int)] = []
        for space in spaces {
            if let last = merged.last, last.start + last.length == space.start {
                merged[merged.count - 1].length += space.length
            } else {
                merged.append(space)
            }
        }
        guard merged.count <= Self.maxFreeSpaces else { throw .discFull }
        free = merged
        writeMap()
    }

    private mutating func writeMap() {
        for i in 0..<Self.maxFreeSpaces {
            put24(i < free.count ? free[i].start : 0, at: i * 3)
            put24(i < free.count ? free[i].length : 0, at: 0x100 + i * 3)
        }
        data[0x1FE] = UInt8(free.count * 3)
        data[0xFF] = ADFSMap.checksum(data[0..<0xFF])
        data[0x1FF] = ADFSMap.checksum(data[0x100..<0x1FF])
    }

    // MARK: Directories

    /// Writes a directory's entries back, sorted by name as ADFS keeps
    /// them, and counts its sequence number on (new and changed entries
    /// take the new one).
    private mutating func write(_ dir: Directory) {
        let base = dir.sector * Self.sectorSize
        let sequence = countSequence(base)
        let old = (try? directory(at: dir.sector).entries) ?? []
        let entries = dir.entries.sorted { $0.name.uppercased() < $1.name.uppercased() }
        for i in 0..<Self.maxEntries {
            let e = base + 5 + i * 26
            guard i < entries.count else {
                if i < 47 {
                    data[e] = 0
                }
                continue
            }
            var entry = entries[i]
            if !old.contains(entry) {
                entry.sequence = sequence
            }
            putText(entry.name, at: e, length: Self.maxNameLength)
            for bit in 0..<5 where entry.attributes & 1 << bit != 0 {
                data[e + bit] |= 0x80
            }
            put32(entry.loadAddress, at: e + 10)
            put32(entry.executionAddress, at: e + 14)
            put32(UInt32(entry.length), at: e + 18)
            put24(entry.startSector, at: e + 22)
            data[e + 25] = entry.sequence
        }
    }

    /// Counts a directory's sequence number on (in BCD), in both copies.
    @discardableResult
    private mutating func countSequence(_ base: Int) -> UInt8 {
        let old = data[base]
        let decimal = (Int(old >> 4) * 10 + Int(old & 0xF) + 1) % 100
        let sequence = UInt8(decimal / 10 << 4 | decimal % 10)
        data[base] = sequence
        data[base + 0x4FA] = sequence
        return sequence
    }

    // MARK: Bytes

    private func get24(_ offset: Int) -> Int {
        Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16
    }

    private func get32(_ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private mutating func put24(_ value: Int, at offset: Int) {
        for i in 0..<3 {
            data[offset + i] = UInt8(value >> (8 * i) & 0xFF)
        }
    }

    private mutating func put32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 {
            data[offset + i] = UInt8(value >> (8 * i) & 0xFF)
        }
    }

    /// Text up to a CR or NUL, without the attribute bits.
    private func text(at offset: Int, length: Int) -> String {
        var chars: [UInt8] = []
        for i in 0..<length {
            let c = data[offset + i] & 0x7F
            if c < 0x20 {
                break
            }
            chars.append(c)
        }
        return String(decoding: chars, as: UTF8.self)
    }

    /// Text padded as ADFS pads it: a CR after, if there's room, then NULs.
    private mutating func putText(_ text: String, at offset: Int, length: Int) {
        let chars = Array(text.utf8.prefix(length))
        for i in 0..<length {
            data[offset + i] = i < chars.count ? chars[i] : i == chars.count ? 0x0D : 0
        }
    }
}
