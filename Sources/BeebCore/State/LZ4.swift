#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// Apple's LZ4 container (what NSData's `.lz4` writes: "bv41" compressed
/// and "bv4-" stored blocks, ending "bv4$"), in Swift so that states saved
/// on a Mac restore where there's no Compression framework (Linux and
/// WebAssembly), and are saved there compressed as the Mac saves them.
enum LZ4 {
    /// Compresses `data` in Apple's container: independent blocks of up to
    /// 64K, each LZ4 (greedy, with a hash of the last place each four
    /// bytes were seen), or stored if that's no smaller.
    static func compress(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count / 2 + 64)
        func append32(_ value: Int) {
            for shift in stride(from: 0, to: 32, by: 8) { output.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        var start = 0
        while start < bytes.count {
            let end = min(start + 65536, bytes.count)
            let block = encodeBlock(bytes[start..<end])
            if block.count < end - start {
                output += Array("bv41".utf8)
                append32(end - start)
                append32(block.count)
                output += block
            } else {
                output += Array("bv4-".utf8)
                append32(end - start)
                output += bytes[start..<end]
            }
            start = end
        }
        output += Array("bv4$".utf8)
        return Data(output)
    }

    /// One LZ4 block of `input`, its matches within it.
    static func encodeBlock(_ input: ArraySlice<UInt8>) -> [UInt8] {
        let source = Array(input)
        let n = source.count
        var output: [UInt8] = []
        output.reserveCapacity(n / 2 + 16)
        var table = [Int](repeating: -1, count: 1 << 14)
        func word(_ i: Int) -> UInt32 {
            UInt32(source[i]) | UInt32(source[i + 1]) << 8 | UInt32(source[i + 2]) << 16 | UInt32(source[i + 3]) << 24
        }
        func hash(_ value: UInt32) -> Int { Int((value &* 2_654_435_761) >> 18) }
        func appendLength(_ length: Int) {
            var rest = length
            while rest >= 255 {
                output.append(255)
                rest -= 255
            }
            output.append(UInt8(rest))
        }
        func sequence(literals: Range<Int>, offset: Int, match: Int) {
            let literalCount = literals.count
            let matchCode = match - 4
            output.append(UInt8(min(literalCount, 15) << 4 | min(matchCode, 15)))
            if literalCount >= 15 { appendLength(literalCount - 15) }
            output += source[literals]
            output.append(UInt8(offset & 0xFF))
            output.append(UInt8(offset >> 8))
            if matchCode >= 15 { appendLength(matchCode - 15) }
        }
        var anchor = 0
        var i = 0
        // The last match starts 12 bytes from the end at the latest, and
        // the last 5 bytes are literals (LZ4's block format).
        while i + 12 < n {
            let value = word(i)
            let h = hash(value)
            let candidate = table[h]
            table[h] = i
            guard candidate >= 0, i - candidate <= 65535, word(candidate) == value else {
                i += 1
                continue
            }
            var length = 4
            while i + length < n - 5 && source[candidate + length] == source[i + length] {
                length += 1
            }
            sequence(literals: anchor..<i, offset: i - candidate, match: length)
            i += length
            anchor = i
        }
        // The last literals, with no match.
        let literalCount = n - anchor
        output.append(UInt8(min(literalCount, 15) << 4))
        if literalCount >= 15 { appendLength(literalCount - 15) }
        output += source[anchor..<n]
        return output
    }

    static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        var p = 0
        func u32(_ i: Int) -> Int? {
            guard i + 4 <= bytes.count else { return nil }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        }
        while p + 4 <= bytes.count {
            let magic = String(decoding: bytes[p..<p + 4], as: UTF8.self)
            switch magic {
            case "bv4$":
                return Data(output)
            case "bv4-":
                guard let size = u32(p + 4), size <= bytes.count - p - 8 else { return nil }
                output += bytes[p + 8..<p + 8 + size]
                p += 8 + size
            case "bv41":
                guard let raw = u32(p + 4), let size = u32(p + 8), size <= bytes.count - p - 12 else { return nil }
                let expected = output.count + raw
                guard block(bytes[p + 12..<p + 12 + size], into: &output), output.count == expected else { return nil }
                p += 12 + size
            default:
                return nil
            }
        }
        return nil
    }

    /// One LZ4 block (https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md),
    /// whose matches may reach back into earlier blocks' output.
    static func block(_ input: ArraySlice<UInt8>, into output: inout [UInt8]) -> Bool {
        var p = input.startIndex
        func length(_ nibble: Int) -> Int? {
            var n = nibble
            guard n == 15 else { return n }
            while true {
                guard p < input.endIndex else { return nil }
                let byte = Int(input[p])
                p += 1
                n += byte
                if byte != 255 { return n }
            }
        }
        while p < input.endIndex {
            let token = Int(input[p])
            p += 1
            guard let literals = length(token >> 4), literals <= input.endIndex - p else { return false }
            output += input[p..<p + literals]
            p += literals
            // The last sequence has no match.
            if p == input.endIndex { return true }
            guard p + 2 <= input.endIndex else { return false }
            let offset = Int(input[p]) | Int(input[p + 1]) << 8
            p += 2
            guard offset > 0, offset <= output.count, let matchLength = length(token & 15) else { return false }
            let start = output.count - offset
            for i in 0..<matchLength + 4 { output.append(output[start + i]) }
        }
        return true
    }
}
