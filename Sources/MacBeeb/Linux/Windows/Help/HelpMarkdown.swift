import Foundation

/// Markdown, as MacBeeb's guides, credits and release notes are written:
/// blocks (headings, paragraphs, lists within lists, code, quotes, tables,
/// images and rules), and their inline text (bold, italic, code and links)
/// as Pango markup for labels. (The Mac's is GuideBlock, in its guide
/// window, with SwiftUI's own inline Markdown.)
enum HelpMarkdown {
    indirect enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        /// Each item its own blocks; `start` is an ordered list's first number.
        case list(ordered: Bool, start: Int, items: [[Block]])
        case code(String)
        case quote([Block])
        /// `header` when the table has one (a |---| row under it).
        case table(header: [String]?, alignments: [Alignment], rows: [[String]])
        /// `path` as written (relative to the document).
        case image(path: String, alt: String)
        case rule
    }

    enum Alignment {
        case leading, center, trailing
    }

    static func parse(_ text: String) -> [Block] {
        let lines = withoutComments(text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
            .map(expandingTabs)
        return blocks(lines[...])
    }

    // MARK: Blocks

    private static func blocks(_ lines: ArraySlice<String>) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            // A line ending in two spaces breaks there; others run on.
            var text = ""
            for (index, line) in paragraph.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                text += trimmed
                if index < paragraph.count - 1 {
                    text += line.hasSuffix("  ") ? "\n" : " "
                }
            }
            result.append(.paragraph(text))
            paragraph = []
        }

        var i = lines.startIndex
        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                i += 1
            } else if let fence = fence(trimmed) {
                flush()
                let indent = indentation(line)
                var code: [String] = []
                i += 1
                while i < lines.endIndex {
                    let next = lines[i]
                    i += 1
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    code.append(dropIndent(next, indent))
                }
                result.append(.code(code.joined(separator: "\n")))
            } else if let (level, text) = heading(trimmed) {
                flush()
                result.append(.heading(level: level, text: text))
                i += 1
            } else if isRule(trimmed) {
                flush()
                result.append(.rule)
                i += 1
            } else if let (alt, path) = image(trimmed) {
                flush()
                result.append(.image(path: path, alt: alt))
                i += 1
            } else if trimmed.hasPrefix("|") {
                flush()
                var rows: [String] = []
                while i < lines.endIndex, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[i])
                    i += 1
                }
                result.append(table(rows))
            } else if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.endIndex {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix(">") else { break }
                    var rest = next.dropFirst()
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    i += 1
                }
                result.append(.quote(blocks(quoted[...])))
            } else if let marker = listMarker(line), paragraph.isEmpty || !marker.ordered || marker.number == 1 {
                // (A list can interrupt a paragraph, but only an ordered one
                // that starts at 1: "1984. " wrapped onto a line isn't one.)
                flush()
                let (list, next) = self.list(lines, from: i, first: marker)
                result.append(list)
                i = next
            } else {
                paragraph.append(line)
                i += 1
            }
        }
        flush()
        return result
    }

    private struct Marker {
        var ordered: Bool
        var number: Int
        /// Where the marker is, and where the item's content starts.
        var indent: Int
        var contentIndent: Int
        var content: String
    }

    /// "- item", "* item", "+ item", "1. item", "1) item".
    private static func listMarker(_ line: String) -> Marker? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        let indent = i
        guard i < chars.count else { return nil }
        var ordered = false
        var number = 0
        if "-*+".contains(chars[i]) {
            i += 1
        } else {
            var digits = 0
            while i < chars.count, digits < 9, let digit = chars[i].wholeNumberValue, chars[i].isASCII {
                number = number * 10 + digit
                i += 1
                digits += 1
            }
            guard digits > 0, i < chars.count, chars[i] == "." || chars[i] == ")" else { return nil }
            i += 1
            ordered = true
        }
        guard i == chars.count || chars[i] == " " else { return nil }
        var spaces = 0
        while i + spaces < chars.count, chars[i + spaces] == " " { spaces += 1 }
        if i + spaces == chars.count {
            return Marker(ordered: ordered, number: number, indent: indent, contentIndent: i + 1, content: "")
        }
        // More than four spaces: the content's indented code, one space in.
        if spaces > 4 { spaces = 1 }
        return Marker(ordered: ordered, number: number, indent: indent, contentIndent: i + spaces,
                      content: String(chars[(i + spaces)...]))
    }

    /// A list from `first`'s line: each item the lines indented under it
    /// (and lines run on lazily), up to a line that isn't the list's.
    private static func list(_ lines: ArraySlice<String>, from start: Int, first: Marker) -> (Block, Int) {
        var items: [[Block]] = []
        var marker = first
        var i = start
        while true {
            var item = [marker.content]
            var afterBlank = false
            i += 1
            while i < lines.endIndex {
                let line = lines[i]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    item.append("")
                    afterBlank = true
                } else if indentation(line) >= marker.contentIndent {
                    item.append(dropIndent(line, marker.contentIndent))
                    afterBlank = false
                } else if !afterBlank, listMarker(line) == nil, !startsBlock(trimmed) {
                    // A paragraph's lazy continuation.
                    item.append(trimmed)
                } else {
                    break
                }
                i += 1
            }
            while item.last?.isEmpty == true { item.removeLast() }
            items.append(blocks(item[...]))
            guard i < lines.endIndex, let next = listMarker(lines[i]), next.ordered == first.ordered else { break }
            marker = next
        }
        return (.list(ordered: first.ordered, start: first.number, items: items), i)
    }

    private static func startsBlock(_ trimmed: String) -> Bool {
        fence(trimmed) != nil || heading(trimmed) != nil || isRule(trimmed) || trimmed.hasPrefix(">")
            || trimmed.hasPrefix("|") || image(trimmed) != nil
    }

    /// "```" or "~~~" (or longer): the fence to close with.
    private static func fence(_ trimmed: String) -> String? {
        for mark in ["```", "~~~"] where trimmed.hasPrefix(mark) {
            return String(trimmed.prefix { $0 == mark.first! })
        }
        return nil
    }

    private static func heading(_ trimmed: String) -> (Int, String)? {
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing #s.
        if let closing = text.lastIndex(where: { $0 != "#" }), text[text.index(after: closing)...].count > 0,
           text[closing] == " " {
            text = String(text[..<closing]).trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// A line that's only an image: ![alt](path "title").
    private static func image(_ trimmed: String) -> (String, String)? {
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")"), let close = trimmed.range(of: "](") else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close.lowerBound])
        var path = String(trimmed[close.upperBound..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        if let space = path.firstIndex(of: " ") { path = String(path[..<space]) }
        if path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
        guard !path.isEmpty, !alt.contains("](") else { return nil }
        return (alt, path)
    }

    private static func table(_ rows: [String]) -> Block {
        let cells = rows.map(cells)
        func isSeparator(_ row: [String]) -> Bool {
            !row.isEmpty && row.allSatisfy { cell in
                let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return !core.isEmpty && core.allSatisfy { $0 == "-" }
            }
        }
        guard cells.count > 1, isSeparator(cells[1]) else {
            return .table(header: nil, alignments: [], rows: cells.filter { !isSeparator($0) })
        }
        let alignments: [Alignment] = cells[1].map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
        return .table(header: cells[0], alignments: alignments, rows: cells.dropFirst(2).filter { !isSeparator($0) })
    }

    /// A row's cells: split at its bars, but not at \| (a bar in a cell).
    private static func cells(_ row: String) -> [String] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Lines

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func dropIndent(_ line: String, _ count: Int) -> String {
        String(line.dropFirst(min(count, indentation(line))))
    }

    private static func expandingTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var result = ""
        for character in line {
            if character == "\t" {
                result += String(repeating: " ", count: 4 - result.count % 4)
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Without <!-- comments -->, which aren't shown.
    private static func withoutComments(_ lines: [String]) -> [String] {
        var result: [String] = []
        var inComment = false
        for line in lines {
            var rest = Substring(line)
            var kept = ""
            while !rest.isEmpty {
                if inComment {
                    guard let end = rest.range(of: "-->") else {
                        rest = ""
                        break
                    }
                    rest = rest[end.upperBound...]
                    inComment = false
                } else if let start = rest.range(of: "<!--") {
                    kept += rest[..<start.lowerBound]
                    rest = rest[start.upperBound...]
                    inComment = true
                } else {
                    kept += rest
                    rest = ""
                }
            }
            // A line that was only a comment goes altogether (rather than
            // becoming a blank line that would split a paragraph).
            if kept.trimmingCharacters(in: .whitespaces).isEmpty && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            result.append(kept)
        }
        return result
    }

    // MARK: Inline text

    /// Inline Markdown as Pango markup: **bold**, *italic*, `code`,
    /// [links](to), <https://autolinks>, and \escapes.
    static func markup(_ text: String) -> String {
        let characters = Array(text)
        return inline(characters, 0..<characters.count, plain: false)
    }

    /// The text without its Markdown, as read aloud or used for anchors.
    static func plain(_ text: String) -> String {
        let characters = Array(text)
        return inline(characters, 0..<characters.count, plain: true)
    }

    /// GitHub's anchor for a heading: "With a Shadow RAM Board" is
    /// "with-a-shadow-ram-board".
    static func anchor(_ heading: String) -> String {
        String(plain(heading).lowercased().compactMap { character -> Character? in
            if character.isLetter || character.isNumber || character == "-" || character == "_" { return character }
            if character == " " { return "-" }
            return nil
        })
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Code's look within text: monospace, a little smaller, on a faint
    /// tint that suits light and dark.
    private static let codeOpen = "<span font_family=\"monospace\" size=\"92%\" bgcolor=\"#80808029\">"

    private static func inline(_ c: [Character], _ range: Range<Int>, plain: Bool) -> String {
        var out = ""
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            let character = c[i]
            switch character {
            case "\\" where i + 1 < end && c[i + 1].isASCII && c[i + 1].isPunctuationOrSymbol:
                out += plain ? String(c[i + 1]) : escape(String(c[i + 1]))
                i += 2
            case "`":
                let n = run(c, i, end)
                if let close = codeClose(c, from: i + n, end, length: n) {
                    var code = String(c[(i + n)..<close]).replacingOccurrences(of: "\n", with: " ")
                    if code.count > 2, code.hasPrefix(" "), code.hasSuffix(" ") {
                        code = String(code.dropFirst().dropLast())
                    }
                    out += plain ? code : codeOpen + escape(code) + "</span>"
                    i = close + n
                } else {
                    out += String(repeating: "`", count: n)
                    i += n
                }
            case "!" where i + 1 < end && c[i + 1] == "[":
                // An image in a line of text: its description.
                if let link = link(c, from: i + 1, end) {
                    out += inline(c, link.text, plain: plain)
                    i = link.next
                } else {
                    out += "!"
                    i += 1
                }
            case "[":
                if let link = link(c, from: i, end) {
                    let text = inline(c, link.text, plain: plain)
                    out += plain ? text : "<a href=\"\(escape(link.url))\">\(text)</a>"
                    i = link.next
                } else {
                    out += plain ? "[" : "["
                    i += 1
                }
            case "<":
                if let close = c[(i + 1)..<end].firstIndex(of: ">") {
                    let url = String(c[(i + 1)..<close])
                    if !url.contains(" "), url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("mailto:") {
                        out += plain ? url : "<a href=\"\(escape(url))\">\(escape(url))</a>"
                        i = close + 1
                        continue
                    }
                }
                out += plain ? "<" : "&lt;"
                i += 1
            case "*", "_":
                let n = run(c, i, end)
                if canOpen(c, i, n, range), let close = emphasisClose(c, from: i + n, end, character: character, length: n) {
                    let inner = inline(c, (i + n)..<close.start, plain: plain)
                    if plain {
                        out += inner
                    } else {
                        switch n {
                        case 1: out += "<i>\(inner)</i>"
                        case 2: out += "<b>\(inner)</b>"
                        default: out += "<b><i>\(inner)</i></b>"
                        }
                    }
                    i = close.next
                } else {
                    out += String(repeating: character, count: n)
                    i += n
                }
            default:
                out += plain ? String(character) : escape(String(character))
                i += 1
            }
        }
        return out
    }

    /// How many of `c[i]` there are in a row.
    private static func run(_ c: [Character], _ i: Int, _ end: Int) -> Int {
        var j = i
        while j < end, c[j] == c[i] { j += 1 }
        return j - i
    }

    /// The backticks closing a code span of `length` backticks.
    private static func codeClose(_ c: [Character], from start: Int, _ end: Int, length: Int) -> Int? {
        var j = start
        while j < end {
            if c[j] == "`" {
                let n = run(c, j, end)
                if n == length { return j }
                j += n
            } else {
                j += 1
            }
        }
        return nil
    }

    /// [text](url): the text's range, the URL, and what follows.
    private static func link(_ c: [Character], from start: Int, _ end: Int) -> (text: Range<Int>, url: String, next: Int)? {
        guard c[start] == "[" else { return nil }
        var depth = 0
        var j = start
        var closeBracket: Int?
        while j < end {
            switch c[j] {
            case "\\": j += 1
            case "`":
                let n = run(c, j, end)
                if let close = codeClose(c, from: j + n, end, length: n) { j = close + n - 1 } else { j += n - 1 }
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { closeBracket = j }
            default: break
            }
            if closeBracket != nil { break }
            j += 1
        }
        guard let close = closeBracket, close + 1 < end, c[close + 1] == "(" else { return nil }
        var parens = 0
        var k = close + 1
        while k < end {
            if c[k] == "(" { parens += 1 }
            if c[k] == ")" {
                parens -= 1
                if parens == 0 { break }
            }
            k += 1
        }
        guard k < end else { return nil }
        var url = String(c[(close + 2)..<k]).trimmingCharacters(in: .whitespaces)
        // A title: [text](url "title").
        if let space = url.firstIndex(of: " ") { url = String(url[..<space]) }
        if url.hasPrefix("<"), url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
        return ((start + 1)..<close, url, k + 1)
    }

    /// Whether a run of * or _ can open emphasis: something other than
    /// space follows, and an _ doesn't start inside a word.
    private static func canOpen(_ c: [Character], _ i: Int, _ n: Int, _ range: Range<Int>) -> Bool {
        guard i + n < range.upperBound, !c[i + n].isWhitespace else { return false }
        if c[i] == "_", i > range.lowerBound, c[i - 1].isLetter || c[i - 1].isNumber { return false }
        return true
    }

    /// The run closing emphasis of `length`: right after something other
    /// than space (and for _, not inside a word). Emphasis of another
    /// length inside it is skipped whole.
    private static func emphasisClose(_ c: [Character], from start: Int, _ end: Int, character: Character,
                                      length: Int) -> (start: Int, next: Int)? {
        var j = start
        while j < end {
            let ch = c[j]
            if ch == "\\" {
                j += 2
                continue
            }
            if ch == "`" {
                let n = run(c, j, end)
                j = (codeClose(c, from: j + n, end, length: n).map { $0 + n }) ?? (j + n)
                continue
            }
            if ch == "[", let link = link(c, from: j, end) {
                j = link.next
                continue
            }
            guard ch == character else {
                j += 1
                continue
            }
            let n = run(c, j, end)
            let after = j + n < end ? c[j + n] : " "
            let closes = !c[j - 1].isWhitespace && (character != "_" || !(after.isLetter || after.isNumber))
            if closes && n >= length {
                // (A longer run closes this and what's inside it: "***".)
                return (j + n - length, j + n)
            }
            if !closes || n != length, canOpen(c, j, n, start..<end),
               let inner = emphasisClose(c, from: j + n, end, character: character, length: n) {
                j = inner.next
                continue
            }
            j += n
        }
        return nil
    }
}

private extension Character {
    var isPunctuationOrSymbol: Bool { isPunctuation || isSymbol }
}
