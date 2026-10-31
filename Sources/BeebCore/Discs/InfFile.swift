#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// A .inf file: the BBC name, addresses and lock of the file it sits
/// beside, as BBC tools leave them when files come off a disc
/// (`$.NAME FFFF1900 FFFF8023 00000123 L`).
public struct InfFile: Sendable, Equatable {
    /// The BBC name, with its DFS directory if it has one ("$.NAME").
    public var name: String
    public var loadAddress: UInt32
    public var executionAddress: UInt32
    public var length: Int?
    public var locked: Bool

    public init(name: String, loadAddress: UInt32, executionAddress: UInt32, length: Int? = nil, locked: Bool = false) {
        self.name = name
        self.loadAddress = loadAddress
        self.executionAddress = executionAddress
        self.length = length
        self.locked = locked
    }

    /// Reads the forms tools write: the name, then load, execution and
    /// length in hex (six-digit addresses from FF meaning the I/O
    /// processor, as eight from FFFF do), then L or Locked, or other
    /// fields (CRC=...), which are ignored.
    public init?(text: String) {
        let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = fields.first else { return nil }
        self.name = name
        var numbers: [String] = []
        locked = false
        for field in fields.dropFirst() {
            if field.uppercased() == "L" || field.uppercased() == "LOCKED" {
                locked = true
            } else if numbers.count < 3, field.count <= 8, UInt32(field, radix: 16) != nil {
                numbers.append(field)
            }
        }
        func address(_ field: String) -> UInt32 {
            let value = UInt32(field, radix: 16)!
            return field.count <= 6 && value >> 16 == 0xFF ? 0xFFFF_0000 | value & 0xFFFF : value
        }
        loadAddress = numbers.count > 0 ? address(numbers[0]) : 0
        executionAddress = numbers.count > 1 ? address(numbers[1]) : 0
        length = numbers.count > 2 ? Int(numbers[2], radix: 16) : nil
    }

    public var text: String {
        var line = name.padding(toLength: max(name.count, 9), withPad: " ", startingAt: 0)
        line += " " + String(format: "%08X %08X", loadAddress, executionAddress)
        if let length {
            line += " " + String(format: "%08X", length)
        }
        if locked {
            line += " L"
        }
        return line + "\n"
    }

    /// A BBC name as a Mac file name: "/" (which DFS and ADFS allow) as
    /// ":", which Finder shows as "/".
    public static func macName(_ bbcName: String) -> String {
        bbcName.replacingOccurrences(of: "/", with: ":")
    }

    public static func bbcName(_ macName: String) -> String {
        macName.replacingOccurrences(of: ":", with: "/")
    }
}
