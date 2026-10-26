// Symbols and source lines from Baron (github.com/waitingforvsync/baron).
//
// Baron writes its symbols as JSON (--symbols), each with the file and
// line that defined it:
//
//   {"format": 2, "assemblies": [{"sources": ["game.6502", "zp.6502"],
//     "sections": [{"name": "code", "attributes": {"filename": "GAME"},
//       "labels": {"start": {"value": 2304, "source": 0, "line": 2}}}]}]}
//
// and its listing (-v) gives each statement's address and bytes beside the
// statement's own source text, but not its line:
//
//   2000  .start
//   2000  A2 00                       LDX #0
//   2004                              addn 3
//   2014                              INCLUDE "inc.6502"
//
// So each statement's text is found in the source, in order: into macros
// (at their calls) and included files (at the INCLUDE), and back round FOR
// loops as many times as the symbols say each loop ran.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension SymbolTable {
    /// Symbols and source lines from a Baron build: its --symbols JSON and,
    /// for each source file on its command line, that file's -v listing.
    /// Relative paths are from `directory`, where Baron ran.
    public static func baron(symbols: Data?, listings: [(source: String, listing: String)], directory: String) -> SymbolTable {
        let dump = symbols.flatMap { BaronSymbols($0, directory: directory) }
        var table = dump?.table ?? SymbolTable()
        for (source, listing) in listings {
            let root = source.hasPrefix("/") ? source : directory.pathAppendingComponent(source)
            var aligner = BaronAligner(root: root, loops: dump?.loops ?? [:])
            for (location, address) in aligner.align(listing) {
                table.addLine(location, address: address)
            }
        }
        return table
    }
}

/// What Baron's --symbols JSON says.
public struct BaronSymbols: Sendable {
    public var table = SymbolTable()
    /// The files read.
    public var sources: [String] = []
    /// Each FOR loop's iterations, by the loop's location.
    var loops: [SourceLocation: Int] = [:]
    /// The filenames of the sections saved, in order.
    public var savedFiles: [String] = []

    /// Relative paths are from `directory`, where Baron ran.
    public init?(_ data: Data, directory: String) {
        #if canImport(FoundationEssentials)
        // (JSONSerialization needs Foundation: Baron runs on the Mac.)
        return nil
        #else
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assemblies = root["assemblies"] as? [[String: Any]] else { return nil }
        var shortNames: [String: Int] = [:]
        var shortCounts: [String: Int] = [:]
        for assembly in assemblies {
            let files = (assembly["sources"] as? [String] ?? []).map { path in
                (path.hasPrefix("/") ? path : directory.pathAppendingComponent(path)).pathStandardized
            }
            sources += files
            for section in assembly["sections"] as? [[String: Any]] ?? [] {
                let attributes = section["attributes"] as? [String: Any] ?? [:]
                if let filename = attributes["filename"] as? String {
                    savedFiles.append(filename)
                }
                func each(_ group: String, _ body: (String, Int, [String: Any]) -> Void) {
                    for (name, entry) in section[group] as? [String: [String: Any]] ?? [:] {
                        guard let value = (entry["value"] as? NSNumber)?.intValue else { continue }
                        body(name, value, entry)
                    }
                }
                // Labels and zero-page variables name their addresses;
                // constants are known by name only. Internal names (with an
                // '@') can't be written in an expression, so they're left out.
                for (group, names) in [("labels", true), ("za_autos", true), ("assignments", false), ("defines", false)] {
                    each(group) { name, value, _ in
                        guard !name.contains("@") else { return }
                        table.add(name, value, names: names)
                        if names, let dot = name.lastIndex(of: ".") {
                            let short = String(name[name.index(after: dot)...])
                            shortNames[short] = value
                            shortCounts[short, default: 0] += 1
                        }
                    }
                }
                each("loop_vars") { _, _, entry in
                    guard let source = (entry["source"] as? NSNumber)?.intValue, files.indices.contains(source),
                          let line = (entry["line"] as? NSNumber)?.intValue else { return }
                    loops[SourceLocation(file: files[source], line: line), default: 0] += 1
                }
            }
        }
        // Scoped labels ("outer.inner") are also known by their own name,
        // when that's unambiguous.
        for (short, value) in shortNames where shortCounts[short] == 1 && table.address(of: short) == nil {
            table.add(short, value)
        }
        #endif
    }
}

struct BaronAligner {
    /// A source file, its lines without comments.
    struct File {
        var path: String
        var lines: [String]
    }

    /// A FOR loop's lines (FOR and NEXT included) in a file.
    struct Loop {
        var file: String
        var lines: ClosedRange<Int>
    }

    /// Where the search is: in a file, or in a macro's body.
    struct Frame {
        var file: String
        /// The lines this frame searches: the whole file, or a macro body.
        var lines: ClosedRange<Int>
        /// The macro's other definitions (overloads), until one matches.
        var alternatives: [ClosedRange<Int>] = []
        var line: Int
        var column: Int
        var isMacro: Bool
        /// The line that called the macro, given the first address in it.
        var call: SourceLocation?
    }

    private var files: [String: File] = [:]
    private var macros: [String: [(file: String, body: ClosedRange<Int>)]] = [:]
    private var loopsIn: [String: [Loop]] = [:]
    /// Passes left round each loop, from the symbols (by its FOR line).
    private var passes: [SourceLocation: Int]
    private let root: String

    init(root: String, loops: [SourceLocation: Int]) {
        self.root = root.pathStandardized
        passes = loops
        load(self.root)
    }

    // MARK: Sources

    /// Reads a file, and the macros and loops it defines (and those of the
    /// files it includes, since a macro is defined before it's used).
    @discardableResult
    private mutating func load(_ path: String) -> File? {
        if let file = files[path] { return file }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n").map { Self.code(String($0.trimmingSuffix("\r"))) }
        let file = File(path: path, lines: lines)
        files[path] = file

        var macroStart: (String, Int)?
        var loopStack: [Int] = []
        var loops: [Loop] = []
        var includes: [String] = []
        for (index, line) in lines.enumerated() {
            for statement in Self.statements(line) {
                let upper = statement.uppercased()
                let word = Self.firstWord(upper)
                if let (name, start) = macroStart {
                    if word == "ENDMACRO" {
                        // (An empty body only declares it.)
                        if index > start + 1 {
                            macros[name, default: []].append((path, (start + 1)...(index - 1)))
                        }
                        macroStart = nil
                    }
                    continue
                }
                switch word {
                case "MACRO":
                    let rest = upper.dropFirst(5).drop { $0 == " " || $0 == "\t" }
                    macroStart = (String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }), index)
                case "FOR":
                    loopStack.append(index)
                case "NEXT":
                    if let start = loopStack.popLast() { loops.append(Loop(file: path, lines: start...index)) }
                case "INCLUDE":
                    if let name = Self.quoted(statement) { includes.append(resolve(name, from: path)) }
                default:
                    break
                }
            }
        }
        loopsIn[path] = loops
        for include in includes { load(include) }
        return file
    }

    private func resolve(_ name: String, from path: String) -> String {
        if name.hasPrefix("/") { return name.pathStandardized }
        return path.pathDeletingLastComponent.pathAppendingComponent(name).pathStandardized
    }

    /// A line without its comment (from `;` or `\` outside quotes).
    static func code(_ line: String) -> String {
        var quote: Character?
        var result = ""
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ";" || ch == "\\" {
                break
            }
            result.append(ch)
        }
        return result
    }

    /// A line's statements, split at colons and braces outside quotes.
    static func statements(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == ":" || ch == "{" || ch == "}" {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func firstWord(_ text: String) -> String {
        String(text.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    static func quoted(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "\""), let close = text[text.index(after: open)...].firstIndex(of: "\"") else { return nil }
        return String(text[text.index(after: open)..<close])
    }

    // MARK: The listing

    enum Item: Equatable {
        /// A label: its address, and the text (".name").
        case label(UInt16, String)
        /// Code or data.
        case code(UInt16, String)
        /// A macro call or INCLUDE: where it lands.
        case marker(UInt16, String)
    }

    /// The listing's lines with an address. The rest (section framing,
    /// braces, assignments, PRINT output) say nothing about addresses.
    static func items(_ listing: String) -> [Item] {
        let byteField = 28
        var items: [Item] = []
        for raw in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = Substring(raw.trimmingSuffix("\r"))
            // "  2000  ..."
            guard line.count > 8, line.hasPrefix("  "),
                  let address = UInt16(line.dropFirst(2).prefix(4), radix: 16),
                  line.dropFirst(6).hasPrefix("  ") else { continue }
            let rest = line.dropFirst(8)
            if rest.hasPrefix(".") {
                items.append(.label(address, String(rest).trimmingCharacters(in: .whitespaces)))
            } else if rest.prefix(byteField).allSatisfy({ $0 == " " }) {
                items.append(.marker(address, String(rest).trimmingCharacters(in: .whitespaces)))
            } else if let first = rest.first, first.isHexDigit {
                var text = String(rest.dropFirst(byteField)).trimmingCharacters(in: .whitespaces)
                // A statement over several lines is cut at the first.
                if text.hasSuffix("...") { text.removeLast(3) }
                items.append(.code(address, text.trimmingCharacters(in: .whitespaces)))
            }
        }
        return items
    }

    /// Source line and address for each statement in the listing.
    mutating func align(_ listing: String) -> [(SourceLocation, UInt16)] {
        guard let rootFile = files[root] else { return [] }
        var result: [(SourceLocation, UInt16)] = []
        var stack = [Frame(file: root, lines: 0...max(0, rootFile.lines.count - 1), line: 0, column: 0, isMacro: false)]
        // The loops the search is in, and whether it has been in them.
        var entered: Set<SourceLocation> = []

        for item in Self.items(listing) {
            let (address, text): (UInt16, String) = switch item {
            case .label(let a, let t), .code(let a, let t), .marker(let a, let t): (a, t)
            }
            guard !text.isEmpty else { continue }
            // Find it, leaving macros and included files that have finished
            // (but not for a statement that can't be found at all).
            var found: (line: Int, column: Int)?
            for depth in stack.indices.reversed() {
                if let hit = find(text, in: &stack[depth], entered: &entered) {
                    stack.removeLast(stack.count - 1 - depth)
                    found = hit
                    break
                }
            }
            guard let (line, _) = found else { continue }
            let frame = stack[stack.count - 1]
            let location = SourceLocation(file: frame.file, line: line + 1)

            switch item {
            case .code:
                result.append((location, address))
                // A macro's call line also gets its first address.
                for i in stack.indices.reversed() where stack[i].call != nil {
                    result.append((stack[i].call!, address))
                    stack[i].call = nil
                }
            case .marker:
                let word = Self.firstWord(text.uppercased())
                if word == "INCLUDE", let name = Self.quoted(text) {
                    let path = resolve(name, from: frame.file)
                    if let file = load(path) {
                        stack.append(Frame(file: path, lines: 0...max(0, file.lines.count - 1), line: 0, column: 0, isMacro: false))
                    }
                } else if let bodies = macros[word], let first = bodies.first {
                    let same = bodies.filter { $0.file == first.file }.map(\.body)
                    stack.append(Frame(file: first.file, lines: first.body, alternatives: Array(same.dropFirst()),
                                       line: first.body.lowerBound, column: 0, isMacro: true, call: location))
                }
            case .label:
                break
            }
        }
        return result
    }

    /// Finds the statement `text` from the frame's position: on through the
    /// loops it's in (or back round them, if they run again), then the rest
    /// of the frame. Moves the frame past it.
    private mutating func find(_ text: String, in frame: inout Frame, entered: inout Set<SourceLocation>) -> (line: Int, column: Int)? {
        guard let file = files[frame.file] else { return nil }
        let loops = (loopsIn[frame.file] ?? []).filter { $0.lines.contains(frame.line) && frame.lines.contains($0.lines.lowerBound) }
            .sorted { $0.lines.count < $1.lines.count }

        func search(_ lines: ClosedRange<Int>, fromColumn column: Int) -> (Int, Int)? {
            for line in lines where file.lines.indices.contains(line) {
                let start = line == lines.lowerBound ? column : 0
                if let at = Self.match(text, in: file.lines[line], from: start) {
                    return (line, at)
                }
            }
            return nil
        }

        func settle(_ hit: (Int, Int)) -> (line: Int, column: Int) {
            frame.line = hit.0
            frame.column = hit.1 + text.count
            // Entering a loop from outside it uses up one of its passes.
            for loop in loopsIn[frame.file] ?? [] where frame.lines.contains(loop.lines.lowerBound) {
                let key = SourceLocation(file: loop.file, line: loop.lines.lowerBound + 1)
                if !loop.lines.contains(hit.0) {
                    entered.remove(key)
                } else if !entered.contains(key) {
                    entered.insert(key)
                    passes[key, default: 1] -= 1
                }
            }
            return (hit.0, hit.1)
        }

        // A macro with overloads: the first body that has it.
        if frame.isMacro, frame.line == frame.lines.lowerBound, frame.column == 0, !frame.alternatives.isEmpty {
            for body in [frame.lines] + frame.alternatives {
                if let hit = search(body, fromColumn: 0) {
                    frame.lines = body
                    frame.alternatives = []
                    return settle(hit)
                }
            }
            return nil
        }

        for loop in loops {
            let end = min(loop.lines.upperBound, frame.lines.upperBound)
            if frame.line <= end, let hit = search(frame.line...end, fromColumn: frame.column) {
                return settle(hit)
            }
            // Round again, if the loop runs again.
            let key = SourceLocation(file: loop.file, line: loop.lines.lowerBound + 1)
            if passes[key, default: 0] > 0, let hit = search(loop.lines.lowerBound...end, fromColumn: 0) {
                passes[key, default: 0] -= 1
                return settle(hit)
            }
        }
        guard frame.line <= frame.lines.upperBound else { return nil }
        if let hit = search(frame.line...frame.lines.upperBound, fromColumn: frame.column) {
            return settle(hit)
        }
        return nil
    }

    /// Where `text` is in `line`, at or after `start`, as a whole statement
    /// or the start of one (a label can be followed by an instruction).
    static func match(_ text: String, in line: String, from start: Int) -> Int? {
        let chars = Array(line)
        let wanted = Array(text)
        guard wanted.count <= chars.count, start <= chars.count - wanted.count else { return nil }
        for i in start...(chars.count - wanted.count) where chars[i] == wanted[0] {
            guard Array(chars[i..<i + wanted.count]) == wanted else { continue }
            let before = i == 0 ? " " : chars[i - 1]
            let after = i + wanted.count == chars.count ? " " : chars[i + wanted.count]
            let separators: Set<Character> = [" ", "\t", ":", "{", "}"]
            if separators.contains(before), separators.contains(after) {
                return i
            }
        }
        return nil
    }
}

private extension StringProtocol {
    func trimmingSuffix(_ suffix: String) -> SubSequence {
        hasSuffix(suffix) ? dropLast(suffix.count) : self[...]
    }
}
