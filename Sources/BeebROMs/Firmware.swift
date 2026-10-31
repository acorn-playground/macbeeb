import BeebCore
#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// Expansion boards' controller ROMs: the versions MacBeeb knows, with
/// their hashes (the bundled one first), so a ROM supplied by the user can
/// be checked. The bundled images' provenance is in ROMs/README.md.
public struct Firmware: Sendable, Equatable, Identifiable {
    /// The file in ROMs/, for a bundled version.
    var image: Image?
    public var board: BBCMicro.MemoryBoard
    public var name: String
    public var version: String
    public var size: Int
    /// SHA-1 as MAME lists it (the same images, under MAME's names).
    public var sha1: String
    public var sha256: String?
    public var mameName: String
    public var id: String { sha1 }

    typealias Image = BeebROMs.Image

    /// Every known version, newest first; the first for each board is
    /// bundled.
    public static let known: [Firmware] = [
        Firmware(image: .watford32KRAM240, board: .watford32K, name: "Shadow RAM OS", version: "2.40", size: 0x2000,
                 sha1: "0a5efb084eb1ae353b9c79c026e9e26cd7695293",
                 sha256: "a2e7c05f809e62faf980096459165fa356cf7c253265131ec68a91bcd2f8bfcb",
                 mameName: "we32kram_v2.40.rom"),
        Firmware(image: nil, board: .watford32K, name: "RAM board ROM", version: "2.20", size: 0x2000,
                 sha1: "7f8536576de449916cd77488e94775ed438c5c6c", sha256: nil, mameName: "we32kram_v2.20.rom"),
        Firmware(image: nil, board: .watford32K, name: "RAM board ROM", version: "2.00", size: 0x2000,
                 sha1: "98a3084b20c92427c2e9def58ade96f42659e20a", sha256: nil, mameName: "we32kram_v2.00.rom"),
        Firmware(image: nil, board: .watford32K, name: "RAM board ROM", version: "1.06", size: 0x2000,
                 sha1: "210f6162d634fca8d75197d4f64d9b50abc01e1e", sha256: nil, mameName: "we32kram_v1.06.rom"),
        Firmware(image: nil, board: .watford32K, name: "RAM board ROM", version: "1.00", size: 0x2000,
                 sha1: "1b59a3354cfc704ad8aa60b0ed16e4cd2d815031", sha256: nil, mameName: "we32kram_v1.00.rom"),
        // MAME calls it v2.2; its header (and the manual's examples) say
        // 1.00.
        Firmware(image: .ariesB32100, board: .ariesB32, name: "ARIES-B32", version: "1.00", size: 0x4000,
                 sha1: "466e3b68f1a8e0287ae095cb3c16dac6afc89dcb",
                 sha256: "8f1e288c08a706f76a43bd8ae296bfb7dce0a3f6244d8f95831261be97a78051",
                 mameName: "aries-b32_v2.2.rom"),
    ]

    /// The bundled version for `board`, if it has a controller ROM.
    public static func standard(for board: BBCMicro.MemoryBoard) -> Firmware? {
        known.first { $0.fits(board) && $0.image != nil }
    }

    /// Whether it's the ROM for `board` (the B32's is the same with or
    /// without the B12).
    public func fits(_ board: BBCMicro.MemoryBoard) -> Bool {
        self.board == board || (self.board == .ariesB32 && board == .ariesB32B12)
    }

    /// Whether MacBeeb comes with this version.
    public var isBundled: Bool { image != nil }

    /// The bundled image, if this version is bundled.
    public var bundledData: [UInt8]? { image.map(BeebROMs.data) }

    public static func sha1(_ bytes: [UInt8]) -> String {
        Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// What an image is: a known version for `board`, or why not.
    public enum Identification: Equatable, Sendable {
        case known(Firmware)
        /// The right size, but not a version MacBeeb knows.
        case unknown(sha256: String)
        case wrongSize(Int, expected: Int)
        case anotherBoard(Firmware)
    }

    public static func identify(_ bytes: [UInt8], for board: BBCMicro.MemoryBoard) -> Identification {
        let hash = sha1(bytes)
        if let match = known.first(where: { $0.sha1 == hash }) {
            return match.fits(board) ? .known(match) : .anotherBoard(match)
        }
        let expected = standard(for: board)?.size ?? 0x4000
        // A 16K dump of an 8K ROM (repeated) is the same ROM.
        if bytes.count == expected * 2, Array(bytes[..<expected]) == Array(bytes[expected...]) {
            return identify(Array(bytes[..<expected]), for: board)
        }
        guard bytes.count == expected else { return .wrongSize(bytes.count, expected: expected) }
        return .unknown(sha256: sha256(bytes))
    }
}
