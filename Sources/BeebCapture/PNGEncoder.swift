#if !canImport(ImageIO)
import CZlib
import Foundation

/// PNG files where there's no ImageIO (Linux): 8-bit RGB, sRGB, each row
/// filtered against the one above (so the TV's doubled scanlines cost
/// almost nothing), deflated by zlib.
public enum PNGEncoder {
    /// From 0x00RRGGBB pixels, `width` x `height`; or (with `alpha`)
    /// 0xAARRGGBB, straight (not premultiplied).
    public static func encode(pixels: [UInt32], width: Int, height: Int, alpha: Bool = false) -> Data? {
        guard width > 0, height > 0, pixels.count >= width * height else { return nil }
        let channels = alpha ? 4 : 3
        let stride = width * channels
        var raw = [UInt8](repeating: 0, count: (stride + 1) * height)
        var previous = [UInt8](repeating: 0, count: stride)
        var row = [UInt8](repeating: 0, count: stride)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = pixels[y * width + x]
                let o = x * channels
                row[o] = UInt8(truncatingIfNeeded: pixel >> 16)
                row[o + 1] = UInt8(truncatingIfNeeded: pixel >> 8)
                row[o + 2] = UInt8(truncatingIfNeeded: pixel)
                if alpha {
                    row[o + 3] = UInt8(truncatingIfNeeded: pixel >> 24)
                }
            }
            let start = y * (stride + 1)
            // Filter type 2, Up (the first row's "above" is zeros).
            raw[start] = 2
            for i in 0..<stride {
                raw[start + 1 + i] = row[i] &- previous[i]
            }
            swap(&row, &previous)
        }
        var compressedLength = compressBound(uLong(raw.count))
        var compressed = [UInt8](repeating: 0, count: Int(compressedLength))
        guard compress2(&compressed, &compressedLength, raw, uLong(raw.count), 6) == Z_OK else { return nil }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.appendBigEndian(UInt32(width))
        header.appendBigEndian(UInt32(height))
        // 8 bits, RGB or RGBA, deflate, adaptive filtering, no interlace.
        header.append(contentsOf: [8, alpha ? 6 : 2, 0, 0, 0])
        png.appendChunk("IHDR", header)
        // sRGB, perceptual.
        png.appendChunk("sRGB", Data([0]))
        png.appendChunk("IDAT", Data(compressed[0..<Int(compressedLength)]))
        png.appendChunk("IEND", Data())
        return png
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    mutating func appendChunk(_ type: String, _ body: Data) {
        appendBigEndian(UInt32(body.count))
        let typed = Data(type.utf8) + body
        append(typed)
        let crc = typed.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
        }
        appendBigEndian(UInt32(truncatingIfNeeded: crc))
    }
}
#endif
