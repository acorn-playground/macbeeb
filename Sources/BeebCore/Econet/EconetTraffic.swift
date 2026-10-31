#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

// Econet traffic as the room protocol carries it (binary WebSocket
// messages, version 1): see cloudflare-econet's econet/docs/protocol.md. The
// test vectors there (protocol/fixtures/traffic.json) are checked against
// this in EconetTrafficTests. It's in the core so that every gateway, the
// Mac app's and the WebAssembly module's, speaks it.

public enum EconetTraffic {
    public static let version: UInt8 = 1
    public static let headerBytes = 12
    public static let maxFrameBytes = 2048

    public enum DecodeError: Error, Equatable {
        case malformed
        case unsupportedVersion
        case tooLarge
        case badAddress
    }

    public static func encode(_ message: EconetGatewayMessage) -> Data {
        let (type, final, stage, transaction, from, to, frame): (UInt8, Bool, Int, UInt32, UInt8, UInt8, [UInt8])
        switch message {
        case .frame(let id, let s, let f, let bytes):
            (type, final, stage, transaction, from, to, frame) = (1, f, s, id, bytes[2], bytes[0], bytes)
        case .noReply(let id, let f, let t):
            (type, final, stage, transaction, from, to, frame) = (2, false, 0, id, f, t, [])
        case .broadcast(let bytes):
            (type, final, stage, transaction, from, to, frame) = (3, false, 0, 0, bytes[2], 255, bytes)
        }
        var out = Data(capacity: headerBytes + frame.count)
        out.append(contentsOf: [version, type, final ? 1 : 0, UInt8(clamping: stage)])
        out.append(contentsOf: [UInt8(transaction >> 24), UInt8(transaction >> 16 & 0xFF), UInt8(transaction >> 8 & 0xFF), UInt8(transaction & 0xFF)])
        out.append(contentsOf: [from, to, UInt8(frame.count >> 8), UInt8(frame.count & 0xFF)])
        out.append(contentsOf: frame)
        return out
    }

    public static func decode(_ data: Data) throws -> EconetGatewayMessage {
        let bytes = [UInt8](data)
        guard bytes.count >= headerBytes else { throw DecodeError.malformed }
        guard bytes[0] == version else { throw DecodeError.unsupportedVersion }
        let length = Int(bytes[10]) << 8 | Int(bytes[11])
        guard length == bytes.count - headerBytes else { throw DecodeError.malformed }
        guard length <= maxFrameBytes else { throw DecodeError.tooLarge }
        let final = bytes[2] & 1 != 0
        let stage = Int(bytes[3])
        let transaction = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        let from = bytes[8], to = bytes[9]
        let frame = Array(bytes[headerBytes...])
        let isStation = { (n: UInt8) in n >= 1 && n <= 254 }
        guard isStation(from) else { throw DecodeError.badAddress }
        if frame.count >= 4 && (frame[0] != to || frame[2] != from) { throw DecodeError.badAddress }
        switch bytes[1] {
        case 1:
            guard frame.count >= 4 else { throw DecodeError.malformed }
            guard isStation(to) else { throw DecodeError.badAddress }
            return .frame(transaction: transaction, stage: stage, final: final, bytes: frame)
        case 2:
            guard frame.isEmpty else { throw DecodeError.malformed }
            guard isStation(to) else { throw DecodeError.badAddress }
            return .noReply(transaction: transaction, from: from, to: to)
        case 3:
            guard frame.count >= 4 else { throw DecodeError.malformed }
            guard to == 255 else { throw DecodeError.badAddress }
            return .broadcast(bytes: frame)
        default:
            throw DecodeError.malformed
        }
    }
}
