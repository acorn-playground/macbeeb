// UEF tape images (https://mdfs.net/Docs/Comp/BBC/FileFormat/UEFSpecs.htm),
// plain or gzipped, read into a `Tape`.
//
// Chunks played: &0100 (8N1 data), &0102 (explicit bits), &0104 (defined
// format data), &0110 (carrier), &0111 (carrier with a dummy &AA byte),
// &0112 and &0116 (gaps), &0113 (base frequency), &0114 (security cycles,
// approximately: each is a whole cycle, high or low, ignoring the half
// cycles at either end), &0117 (300/1200 baud). Everything else (origin,
// instructions, inlay, phase changes, markers, ...) is skipped.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public enum UEF {
    public enum Error: Swift.Error, Equatable {
        case notUEF
        case badGzip
        /// A chunk (its ID) runs off the end of the file.
        case truncated(chunk: UInt16)
    }

    public struct Chunk: Sendable, Equatable {
        public var id: UInt16
        public var data: [UInt8]

        public init(id: UInt16, data: [UInt8]) {
            self.id = id
            self.data = data
        }
    }

    static let identifier = Array("UEF File!\0".utf8)

    /// The chunks of a UEF file, gunzipping it first if need be.
    public static func chunks(_ file: [UInt8]) throws -> [Chunk] {
        let bytes = Gzip.isGzip(file) ? try Gzip.decompress(file) : file
        guard bytes.count >= 12, Array(bytes[0..<10]) == identifier else { throw Error.notUEF }
        var chunks: [Chunk] = []
        var i = 12
        while i + 6 <= bytes.count {
            let id = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
            let size = Int(bytes[i + 2]) | Int(bytes[i + 3]) << 8 | Int(bytes[i + 4]) << 16 | Int(bytes[i + 5]) << 24
            i += 6
            guard size <= bytes.count - i else { throw Error.truncated(chunk: id) }
            chunks.append(Chunk(id: id, data: Array(bytes[i..<i + size])))
            i += size
        }
        return chunks
    }

    /// An uncompressed UEF file of `chunks` (version 0.10).
    public static func file(_ chunks: [Chunk]) -> [UInt8] {
        var bytes = identifier + [10, 0]
        for chunk in chunks {
            let size = UInt32(chunk.data.count)
            bytes += [UInt8(chunk.id & 0xFF), UInt8(chunk.id >> 8)]
            bytes += (0..<4).map { UInt8(size >> ($0 * 8) & 0xFF) }
            bytes += chunk.data
        }
        return bytes
    }

    /// The tape a UEF file plays.
    public static func tape(_ file: [UInt8]) throws -> Tape {
        Tape(segments: segments(try chunks(file)))
    }

    static func segments(_ chunks: [Chunk]) -> [Tape.Segment] {
        var segments: [Tape.Segment] = []
        var rate = Tape.Segment.standardRate
        var slotsPerBit = 2

        func bits(_ bits: [Bool]) -> Tape.Segment {
            .pattern(bits.flatMap { [Tape.Signal](repeating: $0 ? .high : .low, count: slotsPerBit) }, rate: rate)
        }

        for chunk in chunks {
            let d = chunk.data
            func u16(_ i: Int) -> Int { i + 1 < d.count ? Int(d[i]) | Int(d[i + 1]) << 8 : 0 }
            func f32(_ i: Int) -> Double? {
                guard i + 3 < d.count else { return nil }
                let raw = UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
                let value = Double(Float(bitPattern: raw))
                return value.isFinite ? value : nil
            }

            switch chunk.id {
            case 0x0100:
                segments.append(.frames(d, slotsPerBit: slotsPerBit, rate: rate))
            case 0x0102:
                // The first byte: how many of the chunk's bits (counting
                // itself) aren't played. Bits go least significant first.
                guard let unused = d.first else { break }
                let count = min(max(d.count * 8 - Int(unused), 0), (d.count - 1) * 8)
                segments.append(bits((0..<count).map { d[1 + $0 / 8] >> ($0 % 8) & 1 != 0 }))
            case 0x0104:
                guard d.count >= 3, (1...8).contains(d[0]) else { break }
                let parity: Tape.Framing.Parity = switch d[1] {
                case UInt8(ascii: "E"): .even
                case UInt8(ascii: "O"): .odd
                default: .none
                }
                // Negative stop bits (an extra short wave, for the Atom)
                // play as positive.
                let stopBits = min(Int(Int8(bitPattern: d[2]).magnitude), 8)
                let framing = Tape.Framing(dataBits: Int(d[0]), parity: parity, stopBits: stopBits)
                segments.append(.frames(Array(d[3...]), framing, slotsPerBit: slotsPerBit, rate: rate))
            case 0x0110:
                segments.append(.tone(.high, slots: u16(0), rate: rate))
            case 0x0111:
                segments.append(.tone(.high, slots: u16(0), rate: rate))
                segments.append(.frames([0xAA], slotsPerBit: slotsPerBit, rate: rate))
                segments.append(.tone(.high, slots: u16(2), rate: rate))
            case 0x0112:
                segments.append(.tone(.silence, slots: u16(0), rate: rate))
            case 0x0113:
                if let frequency = f32(0), (300...10_000).contains(frequency) {
                    rate = Int((2 * frequency).rounded())
                }
            case 0x0114:
                // 24-bit cycle count, then the first and last cycles'
                // shapes, then a bit a cycle, most significant first: 1 a
                // high tone cycle (a slot), 0 a low one (two).
                guard d.count >= 5 else { break }
                let count = min(Int(d[0]) | Int(d[1]) << 8 | Int(d[2]) << 16, (d.count - 5) * 8)
                let signals = (0..<count).flatMap { i -> [Tape.Signal] in
                    d[5 + i / 8] << (i % 8) & 0x80 != 0 ? [.high] : [.low, .low]
                }
                segments.append(.pattern(signals, rate: rate))
            case 0x0116:
                if let seconds = f32(0), seconds > 0, seconds < 3600 {
                    segments.append(.tone(.silence, slots: Int((seconds * Double(rate)).rounded()), rate: rate))
                }
            case 0x0117:
                let baud = u16(0)
                if baud > 0 && baud <= 2400 {
                    slotsPerBit = 2400 / baud
                }
            default:
                break
            }
        }
        return segments
    }
}

// MARK: gzip and zlib

/// gzip (RFC 1952, including concatenated members) and zlib (RFC 1950)
/// wrappers around raw deflate.
enum Gzip {
    static func isGzip(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B
    }

    static func decompress(_ bytes: [UInt8]) throws(UEF.Error) -> [UInt8] {
        var output: [UInt8] = []
        var i = 0
        // Members follow one another; anything else after the first (zero
        // padding, say) is ignored.
        while i == 0 || isGzip(Array(bytes[i...].prefix(2))) {
            guard bytes.count - i >= 18, bytes[i + 2] == 8 else { throw .badGzip }
            let flags = bytes[i + 3]
            var p = i + 10
            if flags & 0x04 != 0 {
                guard p + 2 <= bytes.count else { throw .badGzip }
                p += 2 + (Int(bytes[p]) | Int(bytes[p + 1]) << 8)
            }
            for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
                // Name, comment: zero terminated.
                while p < bytes.count && bytes[p] != 0 { p += 1 }
                p += 1
            }
            if flags & 0x02 != 0 { p += 2 }
            guard p < bytes.count, let (member, used) = Inflate.inflate(bytes[p...]) else { throw .badGzip }
            p += used
            // The trailer: the member's CRC and size.
            let crc = crc32(member)
            let size = UInt32(truncatingIfNeeded: member.count)
            let trailer = (0..<4).map { UInt8(crc >> ($0 * 8) & 0xFF) } + (0..<4).map { UInt8(size >> ($0 * 8) & 0xFF) }
            guard p + 8 <= bytes.count, bytes[p..<p + 8].elementsEqual(trailer) else { throw .badGzip }
            output += member
            i = p + 8
            if i >= bytes.count { break }
        }
        return output
    }

    /// A zlib stream's contents (the Adler-32 isn't checked).
    static func decompressZlib(_ bytes: ArraySlice<UInt8>) -> [UInt8]? {
        guard bytes.count >= 2 else { return nil }
        let cmf = bytes[bytes.startIndex], flg = bytes[bytes.startIndex + 1]
        guard cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0, flg & 0x20 == 0 else { return nil }
        return inflate(bytes.dropFirst(2))
    }

    /// Inflates the raw deflate stream at the start of `input`, ignoring
    /// anything after it.
    static func inflate(_ input: ArraySlice<UInt8>) -> [UInt8]? {
        Inflate.inflate(input)?.data
    }

    static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ c >> 1 : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ crc >> 8 }
        return ~crc
    }
}
