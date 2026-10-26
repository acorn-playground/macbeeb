// Symbols and source lines, for the debugger.
//
// Loaded from ld65 debug info (`ld65 --dbgfile`, which maps every byte
// back to its source line) or from plain label files:
//
//   main = $2000        name=&2000        .main $2000
//   al C:2000 .main     (VICE)            main EQU $2000
//
// Built in: the OS's entry points and vectors, and the hardware registers.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct SourceLocation: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Absolute path.
    public var file: String
    public var line: Int

    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }

    public var description: String { "\(file.pathLastComponent):\(line)" }
}

public struct SymbolTable: Sendable {
    private(set) var byName: [String: Int] = [:]
    private(set) var byAddress: [UInt16: [String]] = [:]
    private(set) var lineAt: [UInt16: SourceLocation] = [:]
    private(set) var addressesAt: [SourceLocation: [UInt16]] = [:]
    /// The source files lines come from (absolute paths).
    public private(set) var files: Set<String> = []

    public init() {}

    public var isEmpty: Bool { byName.isEmpty && lineAt.isEmpty }
    public var symbolCount: Int { byName.count }
    public var lineCount: Int { lineAt.count }

    /// Adds a symbol. Only `names` symbols (labels, not constants) name
    /// their address in disassembly.
    public mutating func add(_ name: String, _ address: Int, names: Bool = true) {
        byName[name] = address
        guard names, (0...0xFFFF).contains(address) else { return }
        let a = UInt16(address)
        if !(byAddress[a]?.contains(name) ?? false) {
            byAddress[a, default: []].append(name)
        }
    }

    public mutating func addLine(_ location: SourceLocation, address: UInt16) {
        // The first line to claim an address (the instruction, not a macro
        // that expands to it) wins.
        if lineAt[address] == nil {
            lineAt[address] = location
        }
        addressesAt[location, default: []].append(address)
        files.insert(location.file)
    }

    /// Adds everything from `other`, which replaces what's known about its
    /// names and source files (e.g. a rebuild of the same program).
    public mutating func merge(_ other: SymbolTable) {
        // Names that moved stop naming their old address.
        for (name, value) in other.byName {
            if let old = byName[name], old != value, (0...0xFFFF).contains(old) {
                byAddress[UInt16(old)]?.removeAll { $0 == name }
            }
        }
        if !other.files.isEmpty {
            lineAt = lineAt.filter { !other.files.contains($0.value.file) }
            addressesAt = addressesAt.filter { !other.files.contains($0.key.file) }
        }
        // Lines from other programs at the same addresses give way too.
        for address in other.lineAt.keys {
            if let old = lineAt.removeValue(forKey: address) {
                addressesAt[old]?.removeAll { $0 == address }
            }
        }
        for (name, address) in other.byName {
            add(name, address, names: (0...0xFFFF).contains(address) && other.byAddress[UInt16(address)]?.contains(name) == true)
        }
        for (address, location) in other.lineAt { addLine(location, address: address) }
    }

    // MARK: Lookup

    /// A symbol's value (exact match first, then ignoring case).
    public func address(of name: String) -> Int? {
        if let exact = byName[name] {
            return exact
        }
        let upper = name.uppercased()
        return byName.first { $0.key.uppercased() == upper }?.value
    }

    public func names(at address: UInt16) -> [String] {
        byAddress[address] ?? []
    }

    /// The name for an address, preferring a label in the user's code.
    public func name(at address: UInt16) -> String? {
        byAddress[address]?.first
    }

    public func location(at address: UInt16) -> SourceLocation? {
        lineAt[address]
    }

    /// The addresses a source line assembled to. `file` can be a full path
    /// or a file name; if the line has no code, the next one that does is
    /// used (as a debugger moves a breakpoint).
    public func addresses(file: String, line: Int) -> (line: Int, addresses: [UInt16])? {
        let candidates = files.filter { $0 == file || $0.pathLastComponent == file.pathLastComponent }
        guard let path = candidates.first(where: { $0 == file }) ?? candidates.first else { return nil }
        let lines = addressesAt.keys.filter { $0.file == path && $0.line >= line }.map(\.line)
        guard let found = lines.min(), found - line < 50 else { return nil }
        return (found, addressesAt[SourceLocation(file: path, line: found)] ?? [])
    }

    /// The nearest symbol at or below `address` (within 256 bytes), with
    /// the offset: for "routine+5" in call stacks.
    public func nearest(below address: UInt16) -> (name: String, offset: Int)? {
        for offset in 0..<256 where Int(address) - offset >= 0 {
            if let name = byAddress[address &- UInt16(offset)]?.first {
                return (name, offset)
            }
        }
        return nil
    }

    /// Replaces 4-digit addresses ("$FFEE") in disassembly with names.
    public func annotate(_ text: String) -> String {
        guard let dollar = text.firstIndex(of: "$") else { return text }
        let digits = text[text.index(after: dollar)...].prefix { $0.isHexDigit }
        guard digits.count == 4, let value = UInt16(digits, radix: 16), let name = name(at: value) else { return text }
        let end = text.index(dollar, offsetBy: 5)
        return String(text[..<dollar]) + name + text[end...]
    }

    // MARK: Loading

    public enum LoadError: Error, CustomStringConvertible {
        case unreadable(String)
        case empty(String)

        public var description: String {
            switch self {
            case .unreadable(let path): "can't read \(path)"
            case .empty(let path): "no symbols or lines found in \(path)"
            }
        }
    }

    /// Loads a symbol file: ld65 debug info, or a label list.
    public static func load(path: String) throws(LoadError) -> SymbolTable {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw .unreadable(path)
        }
        let table = parse(text, directory: path.pathDeletingLastComponent)
        guard !table.isEmpty else { throw .empty(path) }
        return table
    }

    public static func parse(_ text: String, directory: String = "") -> SymbolTable {
        if text.hasPrefix("version\t") || text.contains("\nseg\tid=") {
            return parseLD65(text, directory: directory)
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[{'") {
            return parseBeebAsmSymbols(text)
        }
        return parseLabels(text)
    }

    /// ld65's --dbgfile format: records like
    /// `line id=3,file=0,line=12,span=4` with key=value fields.
    static func parseLD65(_ text: String, directory: String) -> SymbolTable {
        var files: [Int: String] = [:]
        var segments: [Int: Int] = [:]
        var spans: [Int: (seg: Int, start: Int)] = [:]
        var lines: [(file: Int, line: Int, type: Int, spans: [Int])] = []
        var symbols: [(name: String, value: Int, type: String)] = []

        for record in text.split(separator: "\n") {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let kind = record[..<tab]
            let fields = Self.fields(record[record.index(after: tab)...])
            func int(_ key: String) -> Int? { fields[key].flatMap(Self.number) }
            switch kind {
            case "file":
                if let id = int("id"), let name = fields["name"] {
                    files[id] = name.hasPrefix("/") ? name : directory.pathAppendingComponent(name)
                }
            case "seg":
                if let id = int("id"), let start = int("start") { segments[id] = start }
            case "span":
                if let id = int("id"), let seg = int("seg"), let start = int("start") { spans[id] = (seg, start) }
            case "line":
                if let file = int("file"), let line = int("line"), let list = fields["span"] {
                    lines.append((file, line, int("type") ?? 0, list.split(separator: "+").compactMap { Int($0) }))
                }
            case "sym":
                if let name = fields["name"], let value = int("val") {
                    symbols.append((name, value, fields["type"] ?? "lab"))
                }
            default:
                break
            }
        }

        var table = SymbolTable()
        // ca65 predefines CPU_* constants; equates aren't addresses.
        for symbol in symbols where !symbol.name.hasPrefix("CPU_") {
            table.add(symbol.name, symbol.value, names: symbol.type == "lab")
        }
        // Source lines before macro expansions, so instructions map to the
        // line that wrote them.
        for line in lines.sorted(by: { $0.type < $1.type }) where line.type != 1 {
            guard let file = files[line.file] else { continue }
            for spanID in line.spans {
                guard let span = spans[spanID], let base = segments[span.seg] else { continue }
                let address = base + span.start
                guard (0...0xFFFF).contains(address) else { continue }
                table.addLine(SourceLocation(file: file, line: line.line), address: UInt16(address))
            }
        }
        return table
    }

    private static func fields(_ text: Substring) -> [String: String] {
        var fields: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        func flush() {
            if !key.isEmpty { fields[key] = value }
            key = ""
            value = ""
            inKey = true
        }
        for ch in text {
            if quoted {
                if ch == "\"" { quoted = false } else { value.append(ch) }
            } else if ch == "\"" {
                quoted = true
            } else if ch == "," {
                flush()
            } else if ch == "=" && inKey {
                inKey = false
            } else if inKey {
                key.append(ch)
            } else {
                value.append(ch)
            }
        }
        flush()
        return fields
    }

    static func number(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["0x", "0X", "$", "&"] where t.hasPrefix(prefix) {
            return Int(t.dropFirst(prefix.count), radix: 16)
        }
        return Int(t)
    }

    /// Label lists, one per line.
    static func parseLabels(_ text: String) -> SymbolTable {
        var table = SymbolTable()
        #if canImport(FoundationEssentials)
        // (No NSRegularExpression without Foundation.)
        return table
        #else
        let name = "([A-Za-z_@.][A-Za-z0-9_@.]*)"
        let value = "(?:\\$|&|0x)([0-9A-Fa-f]+)"
        let patterns = [
            // al C:2000 .main (VICE), al 002000 .main (ld65 -Ln)
            "^al\\s+(?:C:)?([0-9A-Fa-f]+)\\s+\\.?" + name,
            // main = $2000, main: $2000, main EQU $2000, .main $2000, main=&2000
            "^\\.?" + name + "\\s*(?::|=|\\s+EQU\\s+|\\s+)\\s*" + value,
        ]
        let regexes = patterns.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            let range = NSRange(s.startIndex..., in: s)
            if let m = regexes[0].firstMatch(in: s, range: range),
               let a = Range(m.range(at: 1), in: s), let n = Range(m.range(at: 2), in: s),
               let address = Int(s[a], radix: 16) {
                table.add(String(s[n]), address)
            } else if let m = regexes[1].firstMatch(in: s, range: range),
                      let n = Range(m.range(at: 1), in: s), let v = Range(m.range(at: 2), in: s),
                      let address = Int(s[v], radix: 16) {
                table.add(String(s[n]), address)
            }
        }
        return table
        #endif
    }

    // MARK: Built in

    /// The OS's entry points and vectors, and (for the host) the hardware
    /// registers.
    public static func builtIn(model: BBCMicro.Model, cpu: DebugCPU, z80: Bool = false) -> SymbolTable {
        var table = SymbolTable()
        if cpu == .parasite && z80 {
            // CP/M's entry points.
            table.add("WBOOT", 0x0000)
            table.add("BDOS", 0x0005)
            return table
        }
        let entries: [(String, Int)] = [
            ("OSCLI", 0xFFF7), ("OSBYTE", 0xFFF4), ("OSWORD", 0xFFF1), ("OSWRCH", 0xFFEE), ("OSNEWL", 0xFFE7),
            ("OSASCI", 0xFFE3), ("OSRDCH", 0xFFE0), ("OSFILE", 0xFFDD), ("OSARGS", 0xFFDA), ("OSBGET", 0xFFD7),
            ("OSBPUT", 0xFFD4), ("OSGBPB", 0xFFD1), ("OSFIND", 0xFFCE),
        ]
        let vectors = ["USERV", "BRKV", "IRQ1V", "IRQ2V", "CLIV", "BYTEV", "WORDV", "WRCHV", "RDCHV", "FILEV",
                       "ARGSV", "BGETV", "BPUTV", "GBPBV", "FINDV", "FSCV", "EVNTV", "UPTV", "NETV", "VDUV",
                       "KEYV", "INSV", "REMV", "CNPV", "IND1V", "IND2V", "IND3V"]
        for (name, address) in entries { table.add(name, address) }
        for (i, name) in vectors.enumerated() { table.add(name, 0x200 + i * 2) }
        if cpu == .parasite {
            for i in 0..<8 { table.add("TUBE_R\(i / 2 + 1)\(i & 1 == 0 ? "STAT" : "DATA")", 0xFEF8 + i) }
            return table
        }
        var hardware: [(String, Int)] = [
            ("CRTC_ADDRESS", 0xFE00), ("CRTC_DATA", 0xFE01), ("ACIA_STATUS", 0xFE08), ("ACIA_DATA", 0xFE09),
            ("SERIAL_ULA", 0xFE10), ("VIDEO_ULA_CONTROL", 0xFE20), ("VIDEO_ULA_PALETTE", 0xFE21), ("ROMSEL", 0xFE30),
        ]
        let via = ["ORB", "ORA", "DDRB", "DDRA", "T1CL", "T1CH", "T1LL", "T1LH", "T2CL", "T2CH", "SR", "ACR", "PCR", "IFR", "IER", "ORA_NH"]
        for (i, register) in via.enumerated() {
            hardware.append(("SYSVIA_\(register)", 0xFE40 + i))
            hardware.append(("USRVIA_\(register)", 0xFE60 + i))
        }
        switch model {
        case .modelA:
            break
        case .modelB:
            hardware += [("FDC_STATUS", 0xFE80), ("FDC_RESULT", 0xFE81), ("FDC_DATA", 0xFE84),
                         ("ADC_STATUS", 0xFEC0), ("ADC_HIGH", 0xFEC1), ("ADC_LOW", 0xFEC2)]
        case .bPlus:
            hardware += [("ACCCON", 0xFE34), ("FDC_CONTROL", 0xFE80), ("FDC_STATUS", 0xFE84), ("FDC_TRACK", 0xFE85),
                         ("FDC_SECTOR", 0xFE86), ("FDC_DATA", 0xFE87), ("ADC_STATUS", 0xFEC0), ("ADC_HIGH", 0xFEC1), ("ADC_LOW", 0xFEC2)]
        case .master128, .masterCompact:
            hardware += [("ACCCON", 0xFE34), ("FDC_CONTROL", 0xFE24), ("FDC_STATUS", 0xFE28), ("FDC_TRACK", 0xFE29),
                         ("FDC_SECTOR", 0xFE2A), ("FDC_DATA", 0xFE2B)]
            if model.hasADC {
                hardware += [("ADC_STATUS", 0xFE18), ("ADC_HIGH", 0xFE19), ("ADC_LOW", 0xFE1A)]
            }
        }
        hardware += (0..<8).map { ("TUBE_\($0)", 0xFEE0 + $0) }
        for (name, address) in hardware { table.add(name, address) }
        return table
    }
}
