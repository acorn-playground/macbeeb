#if !canImport(Darwin)
import CZlib
import Foundation

/// The Compression framework's NSData API, for the tests where there isn't
/// one (Linux): `.zlib`, as Apple's, is raw DEFLATE, here by zlib. The
/// others aren't available, and throw.
extension NSData {
    enum CompressionAlgorithm {
        case zlib, lz4, lzfse, lzma
    }

    struct UnavailableAlgorithm: Error {}

    func compressed(using algorithm: CompressionAlgorithm) throws -> NSData {
        guard algorithm == .zlib else { throw UnavailableAlgorithm() }
        return NSData(data: try Self.deflate([UInt8](self as Data)))
    }

    func decompressed(using algorithm: CompressionAlgorithm) throws -> NSData {
        guard algorithm == .zlib else { throw UnavailableAlgorithm() }
        return NSData(data: try Self.inflate([UInt8](self as Data)))
    }

    private static func deflate(_ input: [UInt8]) throws -> Data {
        var stream = z_stream()
        // -15: raw DEFLATE, no zlib header.
        guard deflateInit2_(&stream, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw UnavailableAlgorithm() }
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))) + 16)
        var input = input
        let status = input.withUnsafeMutableBufferPointer { inBuffer in
            output.withUnsafeMutableBufferPointer { outBuffer in
                stream.next_in = inBuffer.baseAddress
                stream.avail_in = uInt(inBuffer.count)
                stream.next_out = outBuffer.baseAddress
                stream.avail_out = uInt(outBuffer.count)
                return CZlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw UnavailableAlgorithm() }
        return Data(output[0..<Int(stream.total_out)])
    }

    private static func inflate(_ input: [UInt8]) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw UnavailableAlgorithm()
        }
        defer { inflateEnd(&stream) }
        var input = input
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        try input.withUnsafeMutableBufferPointer { inBuffer in
            stream.next_in = inBuffer.baseAddress
            stream.avail_in = uInt(inBuffer.count)
            while true {
                let (status, produced) = chunk.withUnsafeMutableBufferPointer { outBuffer in
                    stream.next_out = outBuffer.baseAddress
                    stream.avail_out = uInt(outBuffer.count)
                    let status = CZlib.inflate(&stream, Z_NO_FLUSH)
                    return (status, outBuffer.count - Int(stream.avail_out))
                }
                result.append(contentsOf: chunk[0..<produced])
                if status == Z_STREAM_END { return }
                guard status == Z_OK else { throw UnavailableAlgorithm() }
            }
        }
        return result
    }
}
#endif
