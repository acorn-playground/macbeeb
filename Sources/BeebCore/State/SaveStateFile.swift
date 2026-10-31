#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
#if os(Linux)
import CLZFSE
#endif

/// A save state file (.beebstate): everything needed to bring a machine
/// back exactly, including its ROMs and discs (with any unsaved writes). Binary plist,
/// compressed.
public struct SaveStateFile: Codable, Sendable {
    public static let fileExtension = "beebstate"
    static let magic = "macbeeb save state"

    var format = Self.magic
    public var created: Date
    public var configuration: BBCMicro.Configuration
    public var snapshot: BBCMicro.Snapshot

    public enum FileError: Error {
        case notASaveState
    }

    /// Captures `machine`'s state.
    public init(_ machine: BBCMicro) {
        created = Date()
        configuration = machine.configuration
        snapshot = machine.snapshot()
    }

    /// Builds a machine in this state.
    public func makeMachine() throws -> BBCMicro {
        let machine = BBCMicro(configuration: configuration)
        // The snapshot includes the discs, exactly.
        try machine.restore(snapshot)
        return machine
    }

    /// The file: compressed with LZFSE (the Compression framework's on the
    /// Mac, Apple's reference implementation on Linux, the same format), or
    /// on WebAssembly, the plain binary plist that `portableData()` gives.
    public func data() throws -> Data {
        #if canImport(Darwin)
        return try (portableData() as NSData).compressed(using: .lzfse) as Data
        #elseif os(Linux)
        return LZFSE.compress(try portableData())
        #else
        return try portableData()
        #endif
    }

    /// The file uncompressed: a binary plist, which every build of MacBeeb
    /// reads (and the only kind it can write without the Compression
    /// framework).
    public func portableData() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    /// Reads a file that `data()` or `portableData()` wrote.
    public init(data: Data) throws {
        var plist = data
        if !data.starts(with: Array("bplist".utf8)) {
            #if canImport(Darwin)
            guard let decompressed = try? (data as NSData).decompressed(using: .lzfse) as Data else {
                throw FileError.notASaveState
            }
            plist = decompressed
            #elseif os(Linux)
            guard let decompressed = LZFSE.decompress(data) else { throw FileError.notASaveState }
            plist = decompressed
            #else
            // (LZFSE needs the Compression framework.)
            throw FileError.notASaveState
            #endif
        }
        self = try PropertyListDecoder().decode(SaveStateFile.self, from: plist)
        guard format == Self.magic else { throw FileError.notASaveState }
    }
}

#if os(Linux)
/// LZFSE through Apple's reference implementation (Sources/CLZFSE).
enum LZFSE {
    static func compress(_ data: Data) -> Data {
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: lzfse_encode_scratch_size(), alignment: 16)
        defer { scratch.deallocate() }
        // At worst the data stored, with block headers.
        var output = [UInt8](repeating: 0, count: data.count + data.count / 16 + 4096)
        let count = data.withUnsafeBytes { source in
            output.withUnsafeMutableBufferPointer { destination in
                lzfse_encode_buffer(destination.baseAddress, destination.count,
                                    source.bindMemory(to: UInt8.self).baseAddress, source.count, scratch)
            }
        }
        return Data(output[0..<count])
    }

    /// nil if it isn't LZFSE.
    static func decompress(_ data: Data) -> Data? {
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: lzfse_decode_scratch_size(), alignment: 16)
        defer { scratch.deallocate() }
        var capacity = max(data.count * 4, 1 << 20)
        while capacity <= 1 << 30 {
            var output = [UInt8](repeating: 0, count: capacity)
            let count = data.withUnsafeBytes { source in
                output.withUnsafeMutableBufferPointer { destination in
                    lzfse_decode_buffer(destination.baseAddress, destination.count,
                                        source.bindMemory(to: UInt8.self).baseAddress, source.count, scratch)
                }
            }
            // A full buffer may mean it didn't fit.
            if count < capacity { return count > 0 ? Data(output[0..<count]) : nil }
            capacity *= 4
        }
        return nil
    }
}
#endif
