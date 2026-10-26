#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Why a change to a disc's files can't be made: the filing system's own
/// errors, mostly.
public enum DiscEditError: Error, Equatable, LocalizedError {
    case badName(String)
    case fileExists(String)
    case locked(String)
    case notFound(String)
    case catalogueFull
    case discFull
    case directoryNotEmpty(String)
    case notFormatted

    public var errorDescription: String? {
        switch self {
        case .badName(let name): "“\(name)” isn’t a name the disc can hold."
        case .fileExists(let name): "There’s already a file or directory called “\(name)”."
        case .locked(let name): "“\(name)” is locked."
        case .notFound(let name): "There’s no “\(name)” on the disc."
        case .catalogueFull: "The catalogue is full."
        case .discFull: "There isn’t room on the disc."
        case .directoryNotEmpty(let name): "The directory “\(name)” isn’t empty."
        case .notFormatted: "The disc isn’t formatted for this filing system."
        }
    }
}

/// Changing a DFS side's files from outside the BBC, as DFS itself would:
/// files are contiguous runs of sectors, catalogued highest first.
extension DFSDisc {
    public static let maxFiles = 31
    public static let maxNameLength = 7

    /// Sectors a file takes.
    static func sectors(_ length: Int) -> Int { (length + sectorSize - 1) / sectorSize }

    public var freeSectors: Int {
        max(0, sectorCount - 2 - files.reduce(0) { $0 + Self.sectors($1.length) })
    }

    /// Whether `name` (without its directory) is one DFS accepts.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= maxNameLength && name.unicodeScalars.allSatisfy(isNameCharacter)
    }

    static func isNameCharacter(_ c: Unicode.Scalar) -> Bool {
        c.value > 0x20 && c.value < 0x7F && !".:\"#*".unicodeScalars.contains(c)
    }

    public static func isValidDirectory(_ directory: Character) -> Bool {
        directory.unicodeScalars.count == 1 && isNameCharacter(directory.unicodeScalars.first!)
    }

    private func index(of directory: Character, _ name: String) -> Int? {
        files.firstIndex {
            $0.directory.uppercased() == directory.uppercased() && $0.name.uppercased() == name.uppercased()
        }
    }

    /// Saves a file, replacing an unlocked one of the same name, in the
    /// first gap big enough (compacting the side if there's none).
    public mutating func save(directory: Character = "$", name: String, loadAddress: UInt32,
                              executionAddress: UInt32, contents: [UInt8], locked: Bool = false) throws(DiscEditError) {
        guard Self.isValidName(name), Self.isValidDirectory(directory) else { throw .badName(name) }
        guard sectorCount > 2, data.count >= 2 * Self.sectorSize else { throw .notFormatted }
        var side = self
        side.padToSize()
        if let existing = side.index(of: directory, name) {
            guard !side.files[existing].locked else { throw .locked("\(directory).\(name)") }
            side.files.remove(at: existing)
        }
        guard side.files.count < Self.maxFiles else { throw .catalogueFull }
        let needed = Self.sectors(contents.count)
        var start = side.freeRun(needed)
        if start == nil {
            side.compact()
            start = side.freeRun(needed)
        }
        guard let start else { throw .discFull }
        side.data.replaceSubrange(start * Self.sectorSize..<start * Self.sectorSize + contents.count, with: contents)
        side.files.append(File(directory: directory, name: name, loadAddress: loadAddress,
                               executionAddress: executionAddress, length: contents.count,
                               startSector: start, locked: locked))
        side.countWrite()
        self = side
    }

    /// The first run of `count` free sectors.
    private func freeRun(_ count: Int) -> Int? {
        var candidate = 2
        for file in files.sorted(by: { $0.startSector < $1.startSector }) {
            if file.startSector - candidate >= count {
                return candidate
            }
            candidate = max(candidate, file.startSector + Self.sectors(file.length))
        }
        return sectorCount - candidate >= count ? candidate : nil
    }

    /// Moves the files down to close the gaps, as *COMPACT does.
    mutating func compact() {
        var next = 2
        for i in files.indices.sorted(by: { files[$0].startSector < files[$1].startSector }) {
            let count = Self.sectors(files[i].length)
            let from = files[i].startSector * Self.sectorSize
            if files[i].startSector != next {
                let bytes = Array(data[from..<from + count * Self.sectorSize])
                data.replaceSubrange(next * Self.sectorSize..<(next + count) * Self.sectorSize, with: bytes)
                files[i].startSector = next
            }
            next += count
        }
    }

    public mutating func delete(_ file: File) throws(DiscEditError) {
        guard let i = index(of: file.directory, file.name) else { throw .notFound(file.fullName) }
        guard !files[i].locked else { throw .locked(file.fullName) }
        files.remove(at: i)
        countWrite()
    }

    public mutating func rename(_ file: File, directory: Character, name: String) throws(DiscEditError) {
        guard Self.isValidName(name), Self.isValidDirectory(directory) else { throw .badName(name) }
        guard let i = index(of: file.directory, file.name) else { throw .notFound(file.fullName) }
        if let other = index(of: directory, name), other != i { throw .fileExists("\(directory).\(name)") }
        files[i].directory = directory
        files[i].name = name
        countWrite()
    }

    /// Changes a file's addresses and lock (which DFS allows when locked).
    public mutating func update(_ file: File, loadAddress: UInt32, executionAddress: UInt32,
                                locked: Bool) throws(DiscEditError) {
        guard let i = index(of: file.directory, file.name) else { throw .notFound(file.fullName) }
        files[i].loadAddress = loadAddress
        files[i].executionAddress = executionAddress
        files[i].locked = locked
        countWrite()
    }

    private mutating func padToSize() {
        let size = sectorCount * Self.sectorSize
        if data.count < size {
            data += [UInt8](repeating: 0, count: size - data.count)
        }
    }

    /// The side's sectors with the catalogue as it now stands.
    public var image: [UInt8] {
        var bytes = data
        if bytes.count < 2 * Self.sectorSize {
            bytes += [UInt8](repeating: 0, count: 2 * Self.sectorSize - bytes.count)
        }
        let title = Array(title.utf8.prefix(12))
        for i in 0..<12 {
            bytes[i < 8 ? i : 0x100 + i - 8] = i < title.count ? title[i] : 0
        }
        bytes[0x104] = writeCycle
        bytes[0x105] = UInt8(files.count * 8)
        bytes[0x106] = UInt8(bootOption & 3) << 4 | UInt8(sectorCount >> 8 & 3)
        bytes[0x107] = UInt8(sectorCount & 0xFF)
        func high(_ address: UInt32) -> UInt8 {
            address >= 0xFFFF_0000 ? 3 : UInt8(address >> 16 & 3)
        }
        // Highest start sector first, as DFS keeps them.
        for (n, file) in files.sorted(by: { $0.startSector > $1.startSector }).enumerated() {
            let entry = 8 + n * 8, info = 0x108 + n * 8
            let name = Array(file.name.utf8)
            for i in 0..<7 {
                bytes[entry + i] = i < name.count ? name[i] : 0x20
            }
            bytes[entry + 7] = UInt8(file.directory.asciiValue ?? 0x24) | (file.locked ? 0x80 : 0)
            bytes[info] = UInt8(file.loadAddress & 0xFF)
            bytes[info + 1] = UInt8(file.loadAddress >> 8 & 0xFF)
            bytes[info + 2] = UInt8(file.executionAddress & 0xFF)
            bytes[info + 3] = UInt8(file.executionAddress >> 8 & 0xFF)
            bytes[info + 4] = UInt8(file.length & 0xFF)
            bytes[info + 5] = UInt8(file.length >> 8 & 0xFF)
            bytes[info + 6] = high(file.executionAddress) << 6 | UInt8(file.length >> 16 & 3) << 4
                | high(file.loadAddress) << 2 | UInt8(file.startSector >> 8 & 3)
            bytes[info + 7] = UInt8(file.startSector & 0xFF)
        }
        // Clear the slots no longer used.
        for n in files.count..<Self.maxFiles {
            for i in 0..<8 {
                bytes[8 + n * 8 + i] = 0
                bytes[0x108 + n * 8 + i] = 0
            }
        }
        return bytes
    }

    /// Counts the write cycle on, in BCD as DFS keeps it.
    mutating func countWrite() {
        let decimal = (Int(writeCycle >> 4) * 10 + Int(writeCycle & 0xF) + 1) % 100
        writeCycle = UInt8(decimal / 10 << 4 | decimal % 10)
    }

    /// An .ssd of one side, or a .dsd of two, interleaved by track.
    public static func image(sides: [DFSDisc]) -> [UInt8] {
        guard sides.count == 2 else { return sides.first?.image ?? [] }
        let trackSize = sectorSize * sectorsPerTrack
        let images = sides.map(\.image)
        let tracks = images.map { ($0.count + trackSize - 1) / trackSize }.max() ?? 0
        var result: [UInt8] = []
        for track in 0..<tracks {
            for image in images {
                let start = min(track * trackSize, image.count), end = min(start + trackSize, image.count)
                result += image[start..<end]
                result += [UInt8](repeating: 0, count: trackSize - (end - start))
            }
        }
        return result
    }
}
