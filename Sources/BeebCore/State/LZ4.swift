#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Apple's LZ4 container (what NSData's `.lz4` writes: "bv41" compressed
/// and "bv4-" stored blocks, ending "bv4$"), decoded in Swift so that
/// states saved on a Mac restore where there's no Compression framework
/// (WebAssembly).
enum LZ4 {
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
