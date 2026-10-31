import Foundation

/// Parses &FF, $FF, 0xFF, %101 or decimal.
func parseNumber(_ text: String) -> Int? {
    let s = text.trimmingCharacters(in: .whitespaces)
    for prefix in ["&", "$", "0x", "0X"] where s.hasPrefix(prefix) {
        return Int(s.dropFirst(prefix.count), radix: 16)
    }
    if s.hasPrefix("%") { return Int(s.dropFirst(), radix: 2) }
    return Int(s)
}

func hex(_ value: some BinaryInteger, _ digits: Int = 2) -> String {
    let text = String(value, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, digits - text.count)) + text
}
