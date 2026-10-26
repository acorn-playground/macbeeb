#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
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

    /// The file: compressed with LZFSE, or, where there's no Compression
    /// framework (WebAssembly), the plain binary plist that `portableData()`
    /// gives.
    public func data() throws -> Data {
        #if canImport(Darwin)
        return try (portableData() as NSData).compressed(using: .lzfse) as Data
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
            #else
            // (LZFSE needs the Compression framework.)
            throw FileError.notASaveState
            #endif
        }
        self = try PropertyListDecoder().decode(SaveStateFile.self, from: plist)
        guard format == Self.magic else { throw FileError.notASaveState }
    }
}
