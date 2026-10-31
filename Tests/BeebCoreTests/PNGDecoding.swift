#if !canImport(ImageIO)
import CZlib
import Foundation

/// PNG decoding for the tests where there's no ImageIO (Linux): 8-bit
/// grey, RGB, palette, grey with alpha and RGBA, not interlaced, as
/// MacBeeb and b2 write them.
enum PNGDecoding {
    struct Image {
        var width: Int
        var height: Int
        /// 0xAARRGGBB, straight.
        var pixels: [UInt32]
    }

    static func decode(_ data: Data) -> Image? {
        let bytes = [UInt8](data)
        guard bytes.count > 8, bytes[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { return nil }
        var offset = 8
        var width = 0, height = 0, colourType = 0
        var palette: [UInt32] = []
        var compressed: [UInt8] = []
        func be32(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
        while offset + 8 <= bytes.count {
            let length = be32(offset)
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            let body = offset + 8
            guard body + length <= bytes.count else { return nil }
            switch type {
            case "IHDR":
                width = be32(body)
                height = be32(body + 4)
                guard bytes[body + 8] == 8, bytes[body + 12] == 0 else { return nil }
                colourType = Int(bytes[body + 9])
            case "PLTE":
                palette = stride(from: body, to: body + length - 2, by: 3).map {
                    0xFF00_0000 | UInt32(bytes[$0]) << 16 | UInt32(bytes[$0 + 1]) << 8 | UInt32(bytes[$0 + 2])
                }
            case "tRNS" where colourType == 3:
                for i in 0..<min(length, palette.count) {
                    palette[i] = palette[i] & 0x00FF_FFFF | UInt32(bytes[body + i]) << 24
                }
            case "IDAT":
                compressed += bytes[body..<body + length]
            default:
                break
            }
            offset = body + length + 4
        }
        let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][colourType] ?? 0
        guard width > 0, height > 0, channels > 0 else { return nil }
        let stride = width * channels
        var raw = [UInt8](repeating: 0, count: (stride + 1) * height)
        var rawLength = uLongf(raw.count)
        guard uncompress(&raw, &rawLength, compressed, uLong(compressed.count)) == Z_OK, Int(rawLength) == raw.count else { return nil }
        // Unfilter in place.
        var previous = [UInt8](repeating: 0, count: stride)
        var pixels = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            let start = y * (stride + 1) + 1
            let filter = raw[start - 1]
            var row = Array(raw[start..<start + stride])
            for i in 0..<stride {
                let a = i >= channels ? Int(row[i - channels]) : 0
                let b = Int(previous[i])
                let c = i >= channels ? Int(previous[i - channels]) : 0
                let predicted: Int
                switch filter {
                case 1: predicted = a
                case 2: predicted = b
                case 3: predicted = (a + b) / 2
                case 4:
                    let p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    predicted = pa <= pb && pa <= pc ? a : pb <= pc ? b : c
                default: predicted = 0
                }
                row[i] = row[i] &+ UInt8(predicted & 0xFF)
            }
            for x in 0..<width {
                let o = x * channels
                pixels[y * width + x] = switch colourType {
                case 0: 0xFF00_0000 | UInt32(row[o]) * 0x010101
                case 2: 0xFF00_0000 | UInt32(row[o]) << 16 | UInt32(row[o + 1]) << 8 | UInt32(row[o + 2])
                case 3: Int(row[o]) < palette.count ? palette[Int(row[o])] : 0
                case 4: UInt32(row[o + 1]) << 24 | UInt32(row[o]) * 0x010101
                default: UInt32(row[o + 3]) << 24 | UInt32(row[o]) << 16 | UInt32(row[o + 1]) << 8 | UInt32(row[o + 2])
                }
            }
            previous = row
        }
        return Image(width: width, height: height, pixels: pixels)
    }
}
#endif
