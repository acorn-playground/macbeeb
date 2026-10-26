#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// BBC BASIC programs as text: listing a tokenised program (as LIST does)
/// and tokenising text (as BASIC does with each line typed in).
///
/// A program is lines of &0D, the line number (high byte first), the
/// line's length and its tokenised text, ending with &0D &FF.
public enum BBCBasic {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case badLineNumber(line: Int)
        case lineTooLong(lineNumber: Int)

        public var errorDescription: String? {
            switch self {
            case .badLineNumber(let line): "Line \(line) of the text has a line number BASIC can’t use."
            case .lineTooLong(let number): "Line \(number) is too long for BASIC."
            }
        }
    }

    /// What a keyword does to the tokenising after it.
    struct Flags: OptionSet {
        let rawValue: UInt8
        /// Not a keyword if a letter, digit or _ follows (TRUE, but not TRUEX).
        static let conditional = Flags(rawValue: 0x01)
        /// Now in the middle of a statement.
        static let middle = Flags(rawValue: 0x02)
        /// Now at the start of a statement.
        static let start = Flags(rawValue: 0x04)
        /// FN and PROC: the name that follows isn't tokenised.
        static let procedureName = Flags(rawValue: 0x08)
        /// Line numbers follow (GOTO 100): they're encoded.
        static let lineNumbers = Flags(rawValue: 0x10)
        /// REM and DATA: the rest of the line isn't tokenised.
        static let restOfLine = Flags(rawValue: 0x20)
        /// PAGE, PTR, TIME, LOMEM, HIMEM: &40 more at the start of a statement
        /// (being assigned to).
        static let pseudoVariable = Flags(rawValue: 0x40)
    }

    /// BASIC 2's keyword table, in its order: the first that matches wins,
    /// so ENDPROC comes before END.
    static let keywords: [(String, UInt8, Flags)] = [
        ("AND", 0x80, []), ("ABS", 0x94, []), ("ACS", 0x95, []), ("ADVAL", 0x96, []), ("ASC", 0x97, []),
        ("ASN", 0x98, []), ("ATN", 0x99, []), ("AUTO", 0xC6, [.lineNumbers]), ("BGET", 0x9A, [.conditional]),
        ("BPUT", 0xD5, [.conditional, .middle]), ("COLOUR", 0xFB, [.middle]), ("CALL", 0xD6, [.middle]),
        ("CHAIN", 0xD7, [.middle]), ("CHR$", 0xBD, []), ("CLEAR", 0xD8, [.conditional]),
        ("CLOSE", 0xD9, [.conditional, .middle]), ("CLG", 0xDA, [.conditional]), ("CLS", 0xDB, [.conditional]),
        ("COS", 0x9B, []), ("COUNT", 0x9C, [.conditional]), ("DATA", 0xDC, [.restOfLine]), ("DEG", 0x9D, []),
        ("DEF", 0xDD, []), ("DELETE", 0xC7, [.lineNumbers]), ("DIV", 0x81, []), ("DIM", 0xDE, [.middle]),
        ("DRAW", 0xDF, [.middle]), ("ENDPROC", 0xE1, [.conditional]), ("END", 0xE0, [.conditional]),
        ("ENVELOPE", 0xE2, [.middle]), ("ELSE", 0x8B, [.start, .lineNumbers]), ("EVAL", 0xA0, []),
        ("ERL", 0x9E, [.conditional]), ("ERROR", 0x85, [.start]), ("EOF", 0xC5, [.conditional]), ("EOR", 0x82, []),
        ("ERR", 0x9F, [.conditional]), ("EXP", 0xA1, []), ("EXT", 0xA2, [.conditional]), ("FOR", 0xE3, [.middle]),
        ("FALSE", 0xA3, [.conditional]), ("FN", 0xA4, [.procedureName]), ("GOTO", 0xE5, [.middle, .lineNumbers]),
        ("GET$", 0xBE, []), ("GET", 0xA5, []), ("GOSUB", 0xE4, [.middle, .lineNumbers]), ("GCOL", 0xE6, [.middle]),
        ("HIMEM", 0x93, [.conditional, .middle, .pseudoVariable]), ("INPUT", 0xE8, [.middle]), ("IF", 0xE7, [.middle]),
        ("INKEY$", 0xBF, []), ("INKEY", 0xA6, []), ("INT", 0xA8, []), ("INSTR(", 0xA7, []),
        ("LIST", 0xC9, [.lineNumbers]), ("LINE", 0x86, []), ("LOAD", 0xC8, [.middle]),
        ("LOMEM", 0x92, [.conditional, .middle, .pseudoVariable]), ("LOCAL", 0xEA, [.middle]), ("LEFT$(", 0xC0, []),
        ("LEN", 0xA9, []), ("LET", 0xE9, [.start]), ("LOG", 0xAB, []), ("LN", 0xAA, []), ("MID$(", 0xC1, []),
        ("MODE", 0xEB, [.middle]), ("MOD", 0x83, []), ("MOVE", 0xEC, [.middle]), ("NEXT", 0xED, [.middle]),
        ("NEW", 0xCA, [.conditional]), ("NOT", 0xAC, []), ("OLD", 0xCB, [.conditional]), ("ON", 0xEE, [.middle]),
        ("OFF", 0x87, []), ("OR", 0x84, []), ("OPENIN", 0x8E, []), ("OPENOUT", 0xAE, []), ("OPENUP", 0xAD, []),
        ("OSCLI", 0xFF, [.middle]), ("PRINT", 0xF1, [.middle]),
        ("PAGE", 0x90, [.conditional, .middle, .pseudoVariable]),
        ("PTR", 0x8F, [.conditional, .middle, .pseudoVariable]), ("PI", 0xAF, [.conditional]),
        ("PLOT", 0xF0, [.middle]), ("POINT(", 0xB0, []), ("PROC", 0xF2, [.middle, .procedureName]),
        ("POS", 0xB1, [.conditional]), ("RETURN", 0xF8, [.conditional]), ("REPEAT", 0xF5, []),
        ("REPORT", 0xF6, [.conditional]), ("READ", 0xF3, [.middle]), ("REM", 0xF4, [.restOfLine]),
        ("RUN", 0xF9, [.conditional]), ("RAD", 0xB2, []), ("RESTORE", 0xF7, [.middle, .lineNumbers]),
        ("RIGHT$(", 0xC2, []), ("RND", 0xB3, [.conditional]), ("RENUMBER", 0xCC, [.lineNumbers]),
        ("STEP", 0x88, []), ("SAVE", 0xCD, [.middle]), ("SGN", 0xB4, []), ("SIN", 0xB5, []), ("SQR", 0xB6, []),
        ("SPC", 0x89, []), ("STR$", 0xC3, []), ("STRING$(", 0xC4, []), ("SOUND", 0xD4, [.middle]),
        ("STOP", 0xFA, [.conditional]), ("TAN", 0xB7, []), ("THEN", 0x8C, [.start, .lineNumbers]), ("TO", 0xB8, []),
        ("TAB(", 0x8A, []), ("TRACE", 0xFC, [.middle, .lineNumbers]),
        ("TIME", 0x91, [.conditional, .middle, .pseudoVariable]), ("TRUE", 0xB9, [.conditional]),
        ("UNTIL", 0xFD, [.middle]), ("USR", 0xBA, []), ("VDU", 0xEF, [.middle]), ("VAL", 0xBB, []),
        ("VPOS", 0xBC, [.conditional]), ("WIDTH", 0xFE, [.middle]),
    ]

    /// Each token's keyword, for listing (pseudo-variables' &40-higher
    /// forms too, and BASIC 4's EDIT).
    static let names: [UInt8: String] = {
        var names: [UInt8: String] = [0xCE: "EDIT"]
        for (word, token, flags) in keywords {
            names[token] = word
            if flags.contains(.pseudoVariable) {
                names[token + 0x40] = word
            }
        }
        return names
    }()

    // MARK: Listing

    /// Whether `bytes` look like a tokenised program: well-formed lines
    /// through to the end marker.
    public static func isProgram(_ bytes: [UInt8]) -> Bool {
        var i = 0
        while i + 1 < bytes.count, bytes[i] == 0x0D {
            if bytes[i + 1] == 0xFF {
                return true
            }
            guard i + 3 < bytes.count, bytes[i + 3] >= 4 else { return false }
            i += Int(bytes[i + 3])
        }
        return false
    }

    /// The program as text, a line per line, as LIST shows it (with the
    /// line numbers right-aligned in 5 columns if `padded`).
    public static func list(_ program: [UInt8], padded: Bool = false) -> String {
        var text = ""
        var i = 0
        while i + 3 < program.count, program[i] == 0x0D, program[i + 1] != 0xFF {
            let number = Int(program[i + 1]) << 8 | Int(program[i + 2])
            let length = Int(program[i + 3])
            guard length >= 4 else { break }
            let line = program[min(i + 4, program.count)..<min(i + length, program.count)]
            let numberText = String(number)
            text += (padded ? String(repeating: " ", count: max(0, 5 - numberText.count)) : "") + numberText
            text += listLine(Array(line)) + "\n"
            i += length
        }
        return text
    }

    static func listLine(_ line: [UInt8]) -> String {
        var text = ""
        var quoted = false
        var literal = false
        var i = 0
        while i < line.count {
            let byte = line[i]
            i += 1
            if byte == 0x22 {
                quoted.toggle()
            }
            if quoted || literal || byte < 0x80 {
                text.unicodeScalars.append(Unicode.Scalar(byte))
                continue
            }
            if byte == 0x8D, i + 3 <= line.count {
                text += String(decodeLineNumber(line[i], line[i + 1], line[i + 2]))
                i += 3
                continue
            }
            text += names[byte] ?? String(Unicode.Scalar(byte))
            if byte == 0xF4 || byte == 0xDC {
                literal = true
            }
        }
        return text
    }

    // MARK: Line numbers after GOTO etc.

    static func encodeLineNumber(_ number: Int) -> [UInt8] {
        let low = UInt8(number & 0xFF), high = UInt8(number >> 8 & 0xFF)
        return [((low & 0xC0) >> 2 | (high & 0xC0) >> 4) ^ 0x54, low & 0x3F | 0x40, high & 0x3F | 0x40]
    }

    static func decodeLineNumber(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Int {
        let top = a ^ 0x54
        let low = top << 2 & 0xC0 | b & 0x3F
        let high = top << 4 & 0xC0 | c & 0x3F
        return Int(high) << 8 | Int(low)
    }

    // MARK: Tokenising

    /// Tokenises a program's text: a line per line, each starting with
    /// its number (lines without one are numbered on from the last, in
    /// tens). Blank lines are skipped.
    public static func tokenise(_ text: String) throws(Error) -> [UInt8] {
        var program: [UInt8] = []
        for line in try numberedLines(text) {
            let body = tokeniseLine(line.body)
            guard body.count + 4 <= 255 else { throw .lineTooLong(lineNumber: line.number) }
            program += [0x0D, UInt8(line.number >> 8), UInt8(line.number & 0xFF), UInt8(body.count + 4)] + body
        }
        return program + [0x0D, 0xFF]
    }

    /// For each line of a program's text with something on it, its BASIC
    /// line number: `textLine` counts from 1. As `tokenise` numbers them.
    public static func lineNumbers(_ text: String) throws(Error) -> [(textLine: Int, number: Int)] {
        try numberedLines(text).map { ($0.textLine, $0.number) }
    }

    /// The text's lines, numbered, with the text after the number.
    static func numberedLines(_ text: String) throws(Error) -> [(textLine: Int, number: Int, body: [UInt8])] {
        var result: [(textLine: Int, number: Int, body: [UInt8])] = []
        var last = 0
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let bytes = Array(rawLine.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
            var i = 0
            while i < bytes.count, bytes[i] == 0x20 {
                i += 1
            }
            guard i < bytes.count else { continue }
            var number = 0
            var digits = 0
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                number = number * 10 + Int(bytes[i] - 0x30)
                digits += 1
                i += 1
                guard number <= 32767 else { throw .badLineNumber(line: index + 1) }
            }
            if digits == 0 {
                number = last + 10
                guard number <= 32767 else { throw .badLineNumber(line: index + 1) }
            }
            last = number
            result.append((index + 1, number, Array(bytes[i...])))
        }
        return result
    }

    static func isIdentifierCharacter(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }

    /// One line's statements, as BASIC tokenises them.
    static func tokeniseLine(_ line: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        var atStart = true
        var lineNumbers = false
        while i < line.count {
            let c = line[i]
            // A string, as it is.
            if c == 0x22 {
                let end = line[(i + 1)...].firstIndex(of: 0x22).map { $0 + 1 } ?? line.count
                out += line[i..<end]
                i = end
                atStart = false
                lineNumbers = false
                continue
            }
            if c == 0x3A {
                out.append(c)
                i += 1
                atStart = true
                lineNumbers = false
                continue
            }
            if c == 0x20 {
                out.append(c)
                i += 1
                continue
            }
            // A star command, as it is.
            if c == 0x2A && atStart {
                out += line[i...]
                break
            }
            // Hex, as it is.
            if c == 0x26 {
                out.append(c)
                i += 1
                while i < line.count, (line[i] >= 0x30 && line[i] <= 0x39) || (line[i] >= 0x41 && line[i] <= 0x46) {
                    out.append(line[i])
                    i += 1
                }
                atStart = false
                lineNumbers = false
                continue
            }
            if c >= 0x30 && c <= 0x39 || c == 0x2E {
                var end = i
                while end < line.count, line[end] >= 0x30 && line[end] <= 0x39 || line[end] == 0x2E {
                    end += 1
                }
                let digits = line[i..<end]
                if lineNumbers, !digits.contains(0x2E), let number = Int(String(decoding: digits, as: UTF8.self)),
                   number <= 32767 {
                    out.append(0x8D)
                    out += encodeLineNumber(number)
                } else {
                    out += digits
                    lineNumbers = false
                }
                i = end
                atStart = false
                continue
            }
            if c == 0x2C {
                out.append(c)
                i += 1
                atStart = false
                continue
            }
            if c >= 0x41 && c <= 0x5A,
               let (word, token, flags) = keywords.first(where: { line[i...].starts(with: $0.0.utf8) }),
               !(flags.contains(.conditional) && i + word.utf8.count < line.count
                 && isIdentifierCharacter(line[i + word.utf8.count])) {
                out.append(flags.contains(.pseudoVariable) && atStart ? token + 0x40 : token)
                i += word.utf8.count
                if flags.contains(.restOfLine) {
                    out += line[i...]
                    break
                }
                if flags.contains(.procedureName) {
                    while i < line.count, isIdentifierCharacter(line[i]) {
                        out.append(line[i])
                        i += 1
                    }
                }
                if flags.contains(.middle) {
                    atStart = false
                }
                if flags.contains(.start) {
                    atStart = true
                }
                lineNumbers = flags.contains(.lineNumbers)
                continue
            }
            // A variable's name, or anything else, as it is.
            if isIdentifierCharacter(c) {
                while i < line.count, isIdentifierCharacter(line[i]) {
                    out.append(line[i])
                    i += 1
                }
            } else {
                out.append(c)
                i += 1
            }
            atStart = false
            lineNumbers = false
        }
        return out
    }
}
