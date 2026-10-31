// CryptoKit's SHA-256 and SHA-1, where there's no CryptoKit (Linux and
// WebAssembly), so code that fingerprints ROMs and discs reads the same on
// every platform: `SHA256.hash(data:)` and `Insecure.SHA1.hash(data:)` give
// the digest's bytes. On the Mac, CryptoKit's own are used.

#if !canImport(CryptoKit)

public enum SHA256 {
    public static func hash<D: Sequence>(data: D) -> [UInt8] where D.Element == UInt8 {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var w = [UInt32](repeating: 0, count: 64)
        MerkleDamgard.blocks(of: Array(data)) { block in
            for i in 0..<16 {
                w[i] = UInt32(block[i * 4]) << 24 | UInt32(block[i * 4 + 1]) << 16
                    | UInt32(block[i * 4 + 2]) << 8 | UInt32(block[i * 4 + 3])
            }
            for i in 16..<64 {
                let s0 = w[i - 15].rotatedRight(7) ^ w[i - 15].rotatedRight(18) ^ (w[i - 15] >> 3)
                let s1 = w[i - 2].rotatedRight(17) ^ w[i - 2].rotatedRight(19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = e.rotatedRight(6) ^ e.rotatedRight(11) ^ e.rotatedRight(25)
                let choice = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ choice &+ k[i] &+ w[i]
                let s0 = a.rotatedRight(2) ^ a.rotatedRight(13) ^ a.rotatedRight(22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return MerkleDamgard.bigEndianBytes(h)
    }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
}

public enum Insecure {
    public enum SHA1 {
        public static func hash<D: Sequence>(data: D) -> [UInt8] where D.Element == UInt8 {
            var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
            var w = [UInt32](repeating: 0, count: 80)
            MerkleDamgard.blocks(of: Array(data)) { block in
                for i in 0..<16 {
                    w[i] = UInt32(block[i * 4]) << 24 | UInt32(block[i * 4 + 1]) << 16
                        | UInt32(block[i * 4 + 2]) << 8 | UInt32(block[i * 4 + 3])
                }
                for i in 16..<80 {
                    w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotatedLeft(1)
                }
                var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
                for i in 0..<80 {
                    let (f, k): (UInt32, UInt32) = switch i {
                    case 0..<20: ((b & c) | (~b & d), 0x5A827999)
                    case 20..<40: (b ^ c ^ d, 0x6ED9EBA1)
                    case 40..<60: ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                    default: (b ^ c ^ d, 0xCA62C1D6)
                    }
                    let t = a.rotatedLeft(5) &+ f &+ e &+ k &+ w[i]
                    e = d; d = c; c = b.rotatedLeft(30); b = a; a = t
                }
                h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
            }
            return MerkleDamgard.bigEndianBytes(h)
        }
    }
}

/// The padding and block structure SHA-1 and SHA-2 share.
private enum MerkleDamgard {
    /// The message padded (a one bit, zeros, and its length in bits), in
    /// 64-byte blocks.
    static func blocks(of message: [UInt8], _ body: ([UInt8]) -> Void) {
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        let bits = UInt64(message.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
        for start in stride(from: 0, to: padded.count, by: 64) {
            body(Array(padded[start..<start + 64]))
        }
    }

    static func bigEndianBytes(_ words: [UInt32]) -> [UInt8] {
        words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (24 - 8 * UInt32($0))) } }
    }
}

private extension UInt32 {
    func rotatedRight(_ n: UInt32) -> UInt32 { (self >> n) | (self << (32 - n)) }
    func rotatedLeft(_ n: UInt32) -> UInt32 { (self << n) | (self >> (32 - n)) }
}

#endif
