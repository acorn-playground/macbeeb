#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// An Acorn DFS disc side: the catalogue in sectors 0 and 1, and the files.
///
/// Reads .ssd images, and each side of .dsd images.
public struct DFSDisc: Sendable {
    public struct File: Sendable, Hashable {
        public var directory: Character
        public var name: String
        public var loadAddress: UInt32
        public var executionAddress: UInt32
        public var length: Int
        public var startSector: Int
        public var locked: Bool

        /// "$.NAME" style.
        public var fullName: String { "\(directory).\(name)" }
    }

    public static let sectorSize = 256
    public static let sectorsPerTrack = 10

    public var title: String {
        didSet { countWrite() }
    }
    /// *OPT 4 setting: 0 none, 1 *LOAD, 2 *RUN, 3 *EXEC !BOOT.
    public var bootOption: Int {
        didSet { countWrite() }
    }
    public var files: [File]
    /// The side's bytes, in logical sector order. (Changes to the title,
    /// boot option and files reach the catalogue sectors in `image`.)
    public internal(set) var data: [UInt8]
    /// Sectors on the side, as the catalogue says.
    public internal(set) var sectorCount: Int
    /// The catalogue's write cycle (BCD), counted up by each change.
    var writeCycle: UInt8

    public enum Error: Swift.Error {
        case tooSmall
        case badCatalogue
    }

    /// `data` is one side's sectors in order (track 0 sector 0 first).
    public init(side data: [UInt8]) throws {
        guard data.count >= 2 * Self.sectorSize else { throw Error.tooSmall }
        self.data = data
        func text(_ range: Range<Int>) -> String {
            String(decoding: data[range].map { $0 & 0x7F }, as: UTF8.self)
                .trimmingCharacters(in: [" ", "\0"])
        }
        title = text(0..<8) + text(0x100..<0x104)
        let entryBytes = Int(data[0x105])
        guard entryBytes % 8 == 0 && entryBytes <= 31 * 8 else { throw Error.badCatalogue }
        bootOption = Int(data[0x106] >> 4 & 3)
        sectorCount = Int(data[0x106] & 3) << 8 | Int(data[0x107])
        writeCycle = data[0x104]

        var files: [File] = []
        for entry in stride(from: 8, through: entryBytes, by: 8) {
            let name = text(entry..<entry + 7)
            let directoryByte = data[entry + 7]
            let info = 0x100 + entry
            let mixed = UInt32(data[info + 6])
            // The high bits of load/exec addresses are 2 bits each; &3 means
            // the I/O processor (&FFFF....).
            func extend(_ low: UInt32, _ high: UInt32) -> UInt32 {
                high == 3 ? 0xFFFF_0000 | low : high << 16 | low
            }
            let load = UInt32(data[info]) | UInt32(data[info + 1]) << 8
            let exec = UInt32(data[info + 2]) | UInt32(data[info + 3]) << 8
            let length = Int(data[info + 4]) | Int(data[info + 5]) << 8 | Int(mixed >> 4 & 3) << 16
            let start = Int(data[info + 7]) | Int(mixed & 3) << 8
            files.append(File(directory: Character(UnicodeScalar(directoryByte & 0x7F)),
                              name: name,
                              loadAddress: extend(load, mixed >> 2 & 3),
                              executionAddress: extend(exec, mixed >> 6 & 3),
                              length: length,
                              startSector: start,
                              locked: directoryByte & 0x80 != 0))
        }
        self.files = files
    }

    /// Sides of an .ssd (1 side) or .dsd (2 sides, interleaved by track).
    public static func sides(ofImage data: [UInt8], doubleSided: Bool) throws -> [DFSDisc] {
        guard doubleSided else { return [try DFSDisc(side: data)] }
        let trackSize = Self.sectorSize * Self.sectorsPerTrack
        var sides: [[UInt8]] = [[], []]
        var offset = 0
        var side = 0
        while offset < data.count {
            sides[side] += data[offset..<min(offset + trackSize, data.count)]
            offset += trackSize
            side ^= 1
        }
        return try sides.filter { !$0.isEmpty }.map { try DFSDisc(side: $0) }
    }

    public func file(named name: String) -> File? {
        let (directory, leaf): (Character, String) = {
            let parts = name.split(separator: ".", maxSplits: 1)
            if parts.count == 2 && parts[0].count == 1 {
                return (parts[0].uppercased().first!, String(parts[1]))
            }
            return ("$", name)
        }()
        return files.first {
            $0.directory.uppercased() == String(directory) && $0.name.uppercased() == leaf.uppercased()
        }
    }

    public func contents(of file: File) -> [UInt8] {
        let start = file.startSector * Self.sectorSize
        let end = min(start + file.length, data.count)
        return start < end ? Array(data[start..<end]) : []
    }
}
