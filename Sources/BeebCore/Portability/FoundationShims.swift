// The few Foundation conveniences BeebCore uses that FoundationEssentials
// (all there is on WebAssembly, where the rest of Foundation would add
// 40MB of ICU data to the module) doesn't have. Only built without full
// Foundation; on the Mac, Foundation's own are used.

#if canImport(FoundationEssentials)
import FoundationEssentials
#if canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The character sets BeebCore trims and splits with, by Foundation's
/// definitions.
struct CharacterSet: Sendable {
    let contains: @Sendable (Unicode.Scalar) -> Bool

    /// Tab and the space separators (Unicode category Zs).
    static let whitespaces = CharacterSet { $0 == "\t" || $0.properties.generalCategory == .spaceSeparator }
    /// U+000A-U+000D, U+0085, U+2028 and U+2029.
    static let newlines = CharacterSet { ("\u{0A}"..."\u{0D}").contains($0) || ["\u{85}", "\u{2028}", "\u{2029}"].contains($0) }
    static let whitespacesAndNewlines = CharacterSet { whitespaces.contains($0) || newlines.contains($0) }

    init(contains: @escaping @Sendable (Unicode.Scalar) -> Bool) {
        self.contains = contains
    }
}

extension CharacterSet: ExpressibleByArrayLiteral {
    init(arrayLiteral scalars: Unicode.Scalar...) {
        let set = Set(scalars)
        contains = { set.contains($0) }
    }
}

extension StringProtocol {
    func trimmingCharacters(in set: CharacterSet) -> String {
        let scalars = Array(unicodeScalars)
        guard let first = scalars.firstIndex(where: { !set.contains($0) }),
              let last = scalars.lastIndex(where: { !set.contains($0) }) else { return "" }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars[first...last])
        return String(result)
    }

    /// Splits at every character in `set`, keeping empty pieces.
    func components(separatedBy set: CharacterSet) -> [String] {
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            if set.contains(scalar) {
                pieces.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        pieces.append(String(current))
        return pieces
    }

    func replacingOccurrences(of target: String, with replacement: String) -> String {
        String(self).replacing(target, with: replacement)
    }

    func padding(toLength length: Int, withPad pad: String, startingAt index: Int) -> String {
        let string = String(self)
        guard string.count < length else { return String(string.prefix(length)) }
        let padding = Array(pad)
        return string + String((0..<length - string.count).map { padding[(index + $0) % padding.count] })
    }
}

extension String {
    /// printf formatting, as C's vsnprintf does it (no %@).
    init(format: String, _ arguments: CVarArg...) {
        func text(_ buffer: [CChar]) -> String {
            String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        self = withVaList(arguments) { list in
            var buffer = [CChar](repeating: 0, count: 256)
            let needed = Int(vsnprintf(&buffer, buffer.count, format, list))
            guard needed >= buffer.count else { return text(buffer) }
            buffer = [CChar](repeating: 0, count: needed + 1)
            return withVaList(arguments) { list in
                _ = vsnprintf(&buffer, buffer.count, format, list)
                return text(buffer)
            }
        }
    }
}

/// WASI (wasip1) has no threads, so there's nothing to lock against.
final class NSLock: @unchecked Sendable {
    func lock() {}
    func unlock() {}
    func withLock<T>(_ body: () throws -> T) rethrows -> T { try body() }
}
#endif
