// Symbols and source lines from BeebAsm.
//
// BeebAsm can dump its labels (-d or -dd, to a file with -labels) as
//
//   [{'start':8192L,'.outer.inner':6400L}]
//
// and print a listing (-v) of every instruction's address, but it doesn't
// say which source line each came from. So the listing is lined up with
// the source: instructions are matched in order by mnemonic, re-syncing at
// each label, following INCLUDEs, mapping macro expansions to the macro's
// lines (and the line that called it), and FOR loops' repeats to the loop
// body.

#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

extension SymbolTable {
    /// Parses a BeebAsm symbol dump.
    static func parseBeebAsmSymbols(_ text: String) -> SymbolTable {
        var table = SymbolTable()
        #if os(WASI)
        // (No NSRegularExpression without Foundation: symbol files are
        // the Mac's business, not the WebAssembly build's.)
        return table
        #else
        let regex = try! NSRegularExpression(pattern: "'([^']+)':(-?[0-9]+)L?")
        var shortNames: [String: Int] = [:]
        var shortCounts: [String: Int] = [:]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let n = Range(match.range(at: 1), in: text), let v = Range(match.range(at: 2), in: text),
                  let value = Int(text[v]) else { continue }
            var name = String(text[n])
            if name.hasPrefix(".") { name.removeFirst() }
            table.add(name, value)
            // Scoped labels ("outer.inner") are also known by their own name,
            // when that's unambiguous.
            if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                let short = String(name[name.index(after: dot)...])
                shortNames[short] = value
                shortCounts[short, default: 0] += 1
            }
        }
        for (short, value) in shortNames where shortCounts[short] == 1 && table.address(of: short) == nil {
            table.add(short, value)
        }
        return table
        #endif
    }

    /// Symbols and source lines from a BeebAsm build: its -v listing, its
    /// symbol dump (optional), and the source file it assembled.
    public static func beebAsm(listing: String, symbols: String?, source: String) -> SymbolTable {
        var table = symbols.map(parseBeebAsmSymbols) ?? SymbolTable()
        // Without a dump, the listing's labels will do.
        if symbols == nil {
            table.merge(BeebAsmAligner.listingLabels(listing))
        }
        let aligner = BeebAsmAligner(source: source)
        for (location, address) in aligner.align(listing) {
            table.addLine(location, address: address)
        }
        return table
    }
}

struct BeebAsmAligner {
    enum Kind: Equatable {
        case label(String)
        case instruction(String)
        case data
        case macroCall(String)
        case other
    }

    struct Statement {
        var location: SourceLocation
        var kind: Kind
    }

    /// The source, flattened: includes expanded, macro bodies set aside.
    private(set) var statements: [Statement] = []
    private(set) var macros: [String: [Statement]] = [:]
    /// For each statement, the innermost FOR loop it's in (first and last
    /// statement indices).
    private(set) var loops: [Int: ClosedRange<Int>] = [:]

    static let mnemonics: Set<String> = [
        "ADC", "AND", "ASL", "BCC", "BCS", "BEQ", "BIT", "BMI", "BNE", "BPL", "BRA", "BRK", "BVC", "BVS", "CLC",
        "CLD", "CLI", "CLV", "CMP", "CPX", "CPY", "DEA", "DEC", "DEX", "DEY", "EOR", "INA", "INC", "INX", "INY",
        "JMP", "JSR", "LDA", "LDX", "LDY", "LSR", "NOP", "ORA", "PHA", "PHP", "PHX", "PHY", "PLA", "PLP", "PLX",
        "PLY", "ROL", "ROR", "RTI", "RTS", "SBC", "SEC", "SED", "SEI", "STA", "STX", "STY", "STZ", "TAX", "TAY",
        "TRB", "TSB", "TSX", "TXA", "TXS", "TYA",
    ]
    static let dataDirectives: Set<String> = ["EQUB", "EQUW", "EQUD", "EQUS", "INCBIN"]

    init(source path: String) {
        var loopStack: [Int] = []
        var loopRanges: [(Int, Int)] = []
        var macroName: String?
        var macroBody: [Statement] = []
        var visited: Set<String> = []

        func flatten(_ path: String) {
            let file = path.pathStandardized
            guard !visited.contains(file), let text = try? String(contentsOfFile: file, encoding: .utf8)
                    ?? String(contentsOfFile: file, encoding: .isoLatin1) else { return }
            visited.insert(file)
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                let location = SourceLocation(file: file, line: index + 1)
                for raw in Self.splitStatements(line) {
                    var statement = raw
                    let upper = statement.uppercased()
                    if let name = macroName {
                        if upper.hasPrefix("ENDMACRO") {
                            macros[name] = macroBody
                            macroName = nil
                        } else if let kind = Self.kind(of: &statement, macros: macros) {
                            macroBody.append(Statement(location: location, kind: kind))
                        }
                        continue
                    }
                    if upper.hasPrefix("MACRO ") {
                        macroName = statement.dropFirst(6).split(whereSeparator: { $0 == " " || $0 == "," }).first.map { String($0).uppercased() }
                        macroBody = []
                        continue
                    }
                    if upper.hasPrefix("INCLUDE ") || upper.hasPrefix("INCLUDE\"") {
                        if let name = Self.quoted(statement) {
                            let relative = file.pathDeletingLastComponent.pathAppendingComponent(name)
                            flatten(FileManager.default.fileExists(atPath: relative) ? relative : name)
                        }
                        continue
                    }
                    if upper.hasPrefix("FOR ") {
                        loopStack.append(statements.count)
                        continue
                    }
                    if upper == "NEXT" || upper.hasPrefix("NEXT ") {
                        if let start = loopStack.popLast() {
                            loopRanges.append((start, statements.count - 1))
                        }
                        continue
                    }
                    // A label, perhaps followed by an instruction.
                    while statement.hasPrefix(".") {
                        let name = statement.dropFirst().prefix { !$0.isWhitespace }
                        statements.append(Statement(location: location, kind: .label(String(name))))
                        statement = String(statement.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
                    }
                    if let kind = Self.kind(of: &statement, macros: macros) {
                        statements.append(Statement(location: location, kind: kind))
                    }
                }
            }
        }
        flatten(path)
        // Innermost loops last, so they win.
        for (start, end) in loopRanges.sorted(by: { $0.1 - $0.0 > $1.1 - $1.0 }) where start <= end {
            for i in start...end { loops[i] = start...end }
        }
    }

    private static func kind(of statement: inout String, macros: [String: [Statement]]) -> Kind? {
        guard !statement.isEmpty else { return nil }
        let word = statement.prefix { $0.isLetter || $0.isNumber || $0 == "_" }.uppercased()
        if word.count >= 3, mnemonics.contains(String(word.prefix(3))), word.count == 3 || !(statement.dropFirst(3).first?.isLetter ?? false) {
            return .instruction(String(word.prefix(3)))
        }
        if dataDirectives.contains(word) { return .data }
        if macros[word] != nil { return .macroCall(word) }
        return .other
    }

    /// A line's statements: comments (\ or ;) removed, split at colons
    /// outside strings.
    static func splitStatements(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for ch in line {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "\\" || ch == ";" {
                break
            } else if ch == ":" {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func quoted(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "\""), let close = text[text.index(after: open)...].firstIndex(of: "\"") else { return nil }
        return String(text[text.index(after: open)..<close])
    }

    // MARK: The listing

    enum ListingItem {
        case label(String)
        case macroStart(String)
        case macroEnd
        case code(address: UInt16, mnemonic: String?)
    }

    static func listing(_ text: String) -> [ListingItem] {
        var items: [ListingItem] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix(".") {
                items.append(.label(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("Macro "), line.hasSuffix(":") {
                items.append(.macroStart(String(line.dropFirst(6).dropLast()).uppercased()))
            } else if line.hasPrefix("End macro") {
                items.append(.macroEnd)
            } else if line.hasPrefix(" ") {
                // "     2002   BD 17 20   LDA &2017,X"
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard let first = fields.first, first.count == 4, let address = UInt16(first, radix: 16) else { continue }
                let mnemonic = fields.dropFirst().first { $0.count == 3 && mnemonics.contains($0.uppercased()) && !$0.allSatisfy(\.isHexDigit) }
                items.append(.code(address: address, mnemonic: mnemonic.map { $0.uppercased() }))
            }
        }
        return items
    }

    /// The labels a listing shows, with the address of the code after
    /// each.
    static func listingLabels(_ text: String) -> SymbolTable {
        var table = SymbolTable()
        var pending: [String] = []
        for item in listing(text) {
            switch item {
            case .label(let name): pending.append(name)
            case .code(let address, _):
                for name in pending { table.add(name, Int(address)) }
                pending = []
            default: break
            }
        }
        return table
    }

    /// Source line and address for each instruction in the listing.
    func align(_ listingText: String) -> [(SourceLocation, UInt16)] {
        var result: [(SourceLocation, UInt16)] = []
        var position = 0
        var macroBody: [Statement]?
        var macroPosition = 0
        var macroCall: SourceLocation?

        func find(_ kind: Kind, from start: Int, to end: Int) -> Int? {
            guard start <= end, start < statements.count else { return nil }
            return (start...min(end, statements.count - 1)).first { statements[$0].kind == kind }
        }

        for item in Self.listing(listingText) {
            switch item {
            case .label(let name):
                let short = String(name.split(separator: ".").last ?? Substring(name))
                if let j = find(.label(short), from: position, to: statements.count - 1) {
                    position = j + 1
                }
            case .macroStart(let name):
                if let j = find(.macroCall(name), from: position, to: position + 200) {
                    macroCall = statements[j].location
                    position = j + 1
                }
                macroBody = macros[name]
                macroPosition = 0
            case .macroEnd:
                macroBody = nil
                macroCall = nil
            case .code(let address, let mnemonic):
                guard let mnemonic else {
                    if macroBody == nil, let j = find(.data, from: position, to: position + 60) {
                        position = j + 1
                    }
                    continue
                }
                let wanted = Kind.instruction(mnemonic)
                if let body = macroBody {
                    if let k = (macroPosition..<body.count).first(where: { body[$0].kind == wanted }) {
                        result.append((body[k].location, address))
                        macroPosition = k + 1
                    }
                    if let call = macroCall {
                        result.append((call, address))
                        macroCall = nil
                    }
                    continue
                }
                // In a loop: the rest of this pass, or the start of the next
                // (which begins with the loop's first instruction).
                if let loop = loops[max(0, position - 1)] ?? loops[position] {
                    let first = (loop.lowerBound...loop.upperBound).first { if case .instruction = statements[$0].kind { true } else { false } }
                    if let j = find(wanted, from: position, to: loop.upperBound)
                        ?? first.flatMap({ statements[$0].kind == wanted ? $0 : nil }) {
                        result.append((statements[j].location, address))
                        position = j + 1
                        continue
                    }
                }
                if let j = find(wanted, from: position, to: position + 60) {
                    result.append((statements[j].location, address))
                    position = j + 1
                }
            }
        }
        return result
    }
}
