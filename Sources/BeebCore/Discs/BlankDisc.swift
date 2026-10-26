#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Blank, formatted disc images, as DFS's *FORM and ADFS's FORM utility
/// leave them: an empty catalogue (DFS) or free space map and root
/// directory (ADFS), ready to save to.
public enum BlankDisc: String, Sendable, CaseIterable, Identifiable {
    case dfs40
    case dfs80
    case dfsDoubleSided40
    case dfsDoubleSided80
    /// ADFS S: 40 tracks, one side.
    case adfsS
    /// ADFS M: 80 tracks, one side.
    case adfsM
    /// ADFS L: 80 tracks, both sides.
    case adfsL

    public var id: Self { self }

    public var name: String {
        switch self {
        case .dfs40: "DFS, 40 tracks, single-sided (100K)"
        case .dfs80: "DFS, 80 tracks, single-sided (200K)"
        case .dfsDoubleSided40: "DFS, 40 tracks, double-sided (200K)"
        case .dfsDoubleSided80: "DFS, 80 tracks, double-sided (400K)"
        case .adfsS: "ADFS S, 40 tracks (160K)"
        case .adfsM: "ADFS M, 80 tracks (320K)"
        case .adfsL: "ADFS L, 80 tracks, double-sided (640K)"
        }
    }

    public var isADFS: Bool { self == .adfsS || self == .adfsM || self == .adfsL }

    public var format: Disc.ImageFormat {
        switch self {
        case .dfs40, .dfs80: .ssd
        case .dfsDoubleSided40, .dfsDoubleSided80: .dsd
        case .adfsS, .adfsM: .adf
        case .adfsL: .adl
        }
    }

    var tracks: Int {
        switch self {
        case .dfs40, .dfsDoubleSided40, .adfsS: 40
        default: 80
        }
    }

    var sides: Int {
        switch self {
        case .dfsDoubleSided40, .dfsDoubleSided80, .adfsL: 2
        default: 1
        }
    }

    /// The longest title the format holds: DFS's 12 characters, or an ADFS
    /// directory title's 19.
    public var maxTitleLength: Int { isADFS ? 19 : 12 }

    /// The formatted image, with `title` (cut to fit) on each DFS side, or
    /// as the ADFS root directory's title.
    public func image(title: String = "") -> [UInt8] {
        let title = Array(title.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }
            .prefix(maxTitleLength).map { UInt8($0.value) })
        if isADFS {
            return Self.adfsImage(sectors: tracks * sides * Disc.adfsSectorsPerTrack, title: title)
        }
        var image = [UInt8](repeating: 0, count: tracks * sides * Disc.ssdTrackSize)
        for side in 0..<sides {
            // A .dsd interleaves the sides by track: side 1's catalogue
            // is track 0's second half.
            let catalogue = Self.dfsCatalogue(sectors: tracks * Disc.ssdSectorsPerTrack, title: title)
            let offset = side * Disc.ssdTrackSize
            image.replaceSubrange(offset..<offset + catalogue.count, with: catalogue)
        }
        return image
    }

    /// Sectors 0 and 1 of an empty DFS side.
    static func dfsCatalogue(sectors: Int, title: [UInt8]) -> [UInt8] {
        var catalogue = [UInt8](repeating: 0, count: 2 * DFSDisc.sectorSize)
        // The title's first 8 characters, then its last 4 in sector 1.
        for (i, c) in title.enumerated() {
            catalogue[i < 8 ? i : 0x100 + i - 8] = c
        }
        // 0x104: the write cycle; 0x105: no files; 0x106: boot option 0
        // and the sector count's top bits.
        catalogue[0x106] = UInt8(sectors >> 8 & 3)
        catalogue[0x107] = UInt8(sectors & 0xFF)
        return catalogue
    }

    /// An empty ADFS (old map) disc: the free space map in sectors 0 and 1,
    /// the root directory in 2 to 6, and everything after it free.
    static func adfsImage(sectors: Int, title: [UInt8]) -> [UInt8] {
        var image = [UInt8](repeating: 0, count: sectors * 256)
        func put24(_ value: Int, at offset: Int) {
            image[offset] = UInt8(value & 0xFF)
            image[offset + 1] = UInt8(value >> 8 & 0xFF)
            image[offset + 2] = UInt8(value >> 16 & 0xFF)
        }
        let rootSector = 2, rootSectors = 5
        let firstFree = rootSector + rootSectors
        // One free space: its start in sector 0, its length in sector 1.
        put24(firstFree, at: 0)
        put24(sectors - firstFree, at: 0x100)
        put24(sectors, at: 0xFC)
        // The disc ID, for spotting a changed disc.
        image[0x1FB] = UInt8.random(in: 0...255)
        image[0x1FC] = UInt8.random(in: 0...255)
        // 0x1FD: boot option 0. 0x1FE: the end of the free space list.
        image[0x1FE] = 3
        image[0xFF] = ADFSMap.checksum(image[0..<0x100])
        image[0x1FF] = ADFSMap.checksum(image[0x100..<0x200])

        // The root directory, "$": no entries, its own parent.
        let dir = rootSector * 256
        let hugo = Array("Hugo".utf8)
        image.replaceSubrange(dir + 1..<dir + 5, with: hugo)
        image[dir + 0x4CC] = UInt8(ascii: "$")
        put24(rootSector, at: dir + 0x4D6)
        let dirTitle = title.isEmpty ? [UInt8(ascii: "$")] : title
        image.replaceSubrange(dir + 0x4D9..<dir + 0x4D9 + dirTitle.count, with: dirTitle)
        if dirTitle.count < 19 {
            image[dir + 0x4D9 + dirTitle.count] = 0x0D
        }
        image.replaceSubrange(dir + 0x4FB..<dir + 0x4FF, with: hugo)
        return image
    }
}

/// The ADFS old map: free space in sectors 0 and 1.
enum ADFSMap {
    /// A map sector's check byte (its last): its other bytes summed from
    /// the end, with each carry added back in, as ADFS checks them.
    static func checksum(_ sector: ArraySlice<UInt8>) -> UInt8 {
        let bytes = Array(sector)
        var total = 255
        for i in stride(from: 254, through: 0, by: -1) {
            if total > 255 {
                total = (total + 1) & 0xFF
            }
            total += Int(bytes[i])
        }
        return UInt8(total & 0xFF)
    }
}
