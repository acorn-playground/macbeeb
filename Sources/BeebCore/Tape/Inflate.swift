// Raw deflate (RFC 1951) decoding, in Swift so that it's the same on every
// platform MacBeeb's core is built for (WebAssembly has no Compression
// framework or zlib). Its canonical Huffman decoding follows Mark Adler's
// puff, zlib's reference inflater.

enum Inflate {
    /// The data in the deflate stream at the start of `input`, and how many
    /// bytes of `input` the stream took; nil if it's malformed or
    /// truncated.
    static func inflate(_ input: ArraySlice<UInt8>) -> (data: [UInt8], used: Int)? {
        var reader = BitReader(bytes: input)
        var output: [UInt8] = []
        while true {
            guard let final = reader.bits(1), let type = reader.bits(2) else { return nil }
            switch type {
            case 0:
                reader.alignToByte()
                guard let len = reader.bits(16), let nlen = reader.bits(16), len == ~nlen & 0xFFFF,
                      let stored = reader.bytes(len) else { return nil }
                output += stored
            case 1:
                guard reader.codes(literals: fixedLiterals, distances: fixedDistances, into: &output) else { return nil }
            case 2:
                guard let (literals, distances) = reader.dynamicTables(),
                      reader.codes(literals: literals, distances: distances, into: &output) else { return nil }
            default:
                return nil
            }
            if final == 1 { return (output, reader.bytesUsed) }
        }
    }

    /// Canonical Huffman decoding table: symbols by code length.
    struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        init?(lengths: [Int]) {
            for length in lengths { counts[length] += 1 }
            counts[0] = 0
            // Over-subscribed code sets are invalid; incomplete ones are
            // allowed (a single distance code, say).
            var left = 1
            for length in 1..<16 {
                left = left << 1 - counts[length]
                if left < 0 { return nil }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }
    }

    static let fixedLiterals = Huffman(lengths: (0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 })!
    static let fixedDistances = Huffman(lengths: [Int](repeating: 5, count: 30))!

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                             35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                              3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                               257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    struct BitReader {
        let bytes: ArraySlice<UInt8>
        var position: Int
        var buffer = 0
        var count = 0

        init(bytes: ArraySlice<UInt8>) {
            self.bytes = bytes
            position = bytes.startIndex
        }

        /// Whole bytes consumed so far (a partly used byte counts).
        var bytesUsed: Int { position - bytes.startIndex }

        mutating func bits(_ n: Int) -> Int? {
            while count < n {
                guard position < bytes.endIndex else { return nil }
                buffer |= Int(bytes[position]) << count
                position += 1
                count += 8
            }
            let value = buffer & (1 << n - 1)
            buffer >>= n
            count -= n
            return value
        }

        mutating func alignToByte() {
            buffer = 0
            count = 0
        }

        mutating func bytes(_ n: Int) -> ArraySlice<UInt8>? {
            guard n <= bytes.endIndex - position else { return nil }
            defer { position += n }
            return bytes[position..<position + n]
        }

        mutating func decode(_ table: Huffman) -> Int? {
            var code = 0, first = 0, index = 0
            for length in 1..<16 {
                guard let bit = bits(1) else { return nil }
                code |= bit
                let count = table.counts[length]
                if code - count < first { return table.symbols[index + code - first] }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            return nil
        }

        mutating func dynamicTables() -> (Huffman, Huffman)? {
            guard let hlit = bits(5), let hdist = bits(5), let hclen = bits(4) else { return nil }
            var codeLengths = [Int](repeating: 0, count: 19)
            for i in 0..<hclen + 4 {
                guard let length = bits(3) else { return nil }
                codeLengths[Inflate.codeLengthOrder[i]] = length
            }
            guard let lengthCode = Huffman(lengths: codeLengths) else { return nil }
            var lengths: [Int] = []
            let total = hlit + 257 + hdist + 1
            while lengths.count < total {
                guard let symbol = decode(lengthCode) else { return nil }
                switch symbol {
                case 0..<16:
                    lengths.append(symbol)
                case 16:
                    guard let last = lengths.last, let n = bits(2) else { return nil }
                    lengths += [Int](repeating: last, count: 3 + n)
                case 17:
                    guard let n = bits(3) else { return nil }
                    lengths += [Int](repeating: 0, count: 3 + n)
                default:
                    guard let n = bits(7) else { return nil }
                    lengths += [Int](repeating: 0, count: 11 + n)
                }
            }
            guard lengths.count == total, lengths[256] != 0,
                  let literals = Huffman(lengths: Array(lengths[0..<hlit + 257])),
                  let distances = Huffman(lengths: Array(lengths[(hlit + 257)...])) else { return nil }
            return (literals, distances)
        }

        mutating func codes(literals: Huffman, distances: Huffman, into output: inout [UInt8]) -> Bool {
            while true {
                guard let symbol = decode(literals) else { return false }
                if symbol < 256 {
                    output.append(UInt8(symbol))
                } else if symbol == 256 {
                    return true
                } else {
                    let l = symbol - 257
                    guard l < 29, let lengthBits = bits(Inflate.lengthExtra[l]),
                          let d = decode(distances), d < 30, let distanceBits = bits(Inflate.distanceExtra[d]) else {
                        return false
                    }
                    let length = Inflate.lengthBase[l] + lengthBits
                    let distance = Inflate.distanceBase[d] + distanceBits
                    guard distance <= output.count else { return false }
                    let start = output.count - distance
                    for i in 0..<length { output.append(output[start + i]) }
                }
            }
        }
    }
}
