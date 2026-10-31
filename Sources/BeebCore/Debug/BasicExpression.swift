#if os(WASI)
import FoundationEssentials
#if canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#else
import Foundation
#endif

/// A BASIC expression, for breakpoint conditions and watching values:
/// numbers (&hex too), strings, variables and array elements, ? ! and $
/// indirection, PAGE, TOP, LOMEM, HIMEM, ERR, ERL, TRUE and FALSE, and
/// BASIC's operators, with its precedence:
///   ^, then * / DIV MOD, + -, = <> < > <= >=, AND, OR EOR.
/// No functions: evaluating mustn't run any BASIC.
public struct BasicExpression: Sendable, CustomStringConvertible {
    public let source: String
    let root: Node

    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public var message: String
        public var description: String { message }
    }

    public struct EvaluationError: Error, CustomStringConvertible, Equatable {
        public var message: String
        public var description: String { message }
    }

    /// What an expression can see.
    struct Context {
        var variable: (String) -> BasicValue?
        var element: (String, [Int]) -> BasicValue?
        var memory: BasicMemory
    }

    indirect enum Node: Sendable {
        case value(BasicValue)
        case variable(String)
        case element(String, [Node])
        case pseudo(String)
        case unary(String, Node)
        case binary(String, Node, Node)
    }

    public init(_ source: String) throws(ParseError) {
        self.source = source
        var parser = Parser(tokens: try Self.tokenise(source))
        root = try parser.expression()
        guard parser.index == parser.tokens.count else {
            throw ParseError(message: "unexpected \(parser.tokens[parser.index].text) in \(source)")
        }
    }

    public var description: String { source }

    func evaluate(_ context: Context) throws(EvaluationError) -> BasicValue {
        try Self.evaluate(root, context)
    }

    func isTrue(_ context: Context) throws(EvaluationError) -> Bool {
        let value = try evaluate(context)
        guard let n = value.number else { throw EvaluationError(message: "a condition must be a number") }
        return n != 0
    }

    // MARK: Evaluating

    static func evaluate(_ node: Node, _ c: Context) throws(EvaluationError) -> BasicValue {
        switch node {
        case .value(let v):
            return v
        case .variable(let name):
            guard let v = c.variable(name) else { throw EvaluationError(message: "no such variable: \(name)") }
            return v
        case .element(let name, let indices):
            var values: [Int] = []
            for index in indices {
                values.append(Int(try integer(evaluate(index, c))))
            }
            guard let v = c.element(name, values) else {
                throw EvaluationError(message: "no such element: \(name)\(values.map(String.init).joined(separator: ",")))")
            }
            return v
        case .pseudo(let name):
            let m = c.memory
            switch name {
            case "PAGE": return .integer(Int32(m.page))
            case "TOP": return .integer(Int32(m.top))
            case "LOMEM": return .integer(Int32(m.lomem))
            case "HIMEM": return .integer(Int32(m.himem))
            case "ERL": return .integer(Int32(m.word(0x08)))
            case "ERR": return .integer(Int32(m[m.word(0xFD)]))
            case "TRUE": return .integer(-1)
            default: return .integer(0)
            }
        case .unary(let op, let operand):
            let v = try evaluate(operand, c)
            switch op {
            case "-":
                if case .integer(let n) = v, n != .min { return .integer(-n) }
                return .real(-(try number(v)))
            case "+":
                _ = try number(v)
                return v
            case "NOT":
                return .integer(~(try integer(v)))
            case "?":
                return .integer(Int32(c.memory[Int(try integer(v))]))
            case "!":
                return c.memory.integer(at: Int(try integer(v)) & 0xFFFF)
            default:
                return .string(c.memory.string(at: Int(try integer(v)) & 0xFFFF))
            }
        case .binary(let op, let l, let r):
            return try binary(op, try evaluate(l, c), try evaluate(r, c))
        }
    }

    static func number(_ v: BasicValue) throws(EvaluationError) -> Double {
        guard let n = v.number else { throw EvaluationError(message: "type mismatch: a string isn't a number") }
        return n
    }

    static func integer(_ v: BasicValue) throws(EvaluationError) -> Int32 {
        if case .integer(let n) = v { return n }
        let x = try number(v).rounded(.towardZero)
        guard x >= -2_147_483_648, x <= 4_294_967_295 else { throw EvaluationError(message: "too big for an integer") }
        return x > 2_147_483_647 ? Int32(bitPattern: UInt32(x)) : Int32(x)
    }

    static func truth(_ b: Bool) -> BasicValue { .integer(b ? -1 : 0) }

    static func binary(_ op: String, _ l: BasicValue, _ r: BasicValue) throws(EvaluationError) -> BasicValue {
        if case .string(let a) = l {
            guard case .string(let b) = r else { throw EvaluationError(message: "type mismatch: comparing a string with a number") }
            let x = Array(a.unicodeScalars.map(\.value)), y = Array(b.unicodeScalars.map(\.value))
            switch op {
            case "+": return .string(a + b)
            case "=": return truth(x == y)
            case "<>": return truth(x != y)
            case "<": return truth(x.lexicographicallyPrecedes(y))
            case ">": return truth(y.lexicographicallyPrecedes(x))
            case "<=": return truth(!y.lexicographicallyPrecedes(x))
            case ">=": return truth(!x.lexicographicallyPrecedes(y))
            default: throw EvaluationError(message: "type mismatch: \(op) of strings")
            }
        }
        if case .string = r { throw EvaluationError(message: "type mismatch: comparing a number with a string") }
        switch op {
        case "AND": return .integer(try integer(l) & integer(r))
        case "OR": return .integer(try integer(l) | integer(r))
        case "EOR": return .integer(try integer(l) ^ integer(r))
        case "DIV", "MOD":
            let a = try integer(l), b = try integer(r)
            guard b != 0 else { throw EvaluationError(message: "division by zero") }
            guard !(a == .min && b == -1) else { return .integer(op == "DIV" ? .min : 0) }
            return .integer(op == "DIV" ? a / b : a % b)
        default:
            break
        }
        let a = try number(l), b = try number(r)
        if case .integer(let x) = l, case .integer(let y) = r {
            let result: (Int32, Bool)? = switch op {
            case "+": x.addingReportingOverflow(y)
            case "-": x.subtractingReportingOverflow(y)
            case "*": x.multipliedReportingOverflow(by: y)
            default: nil
            }
            if let result, !result.1 { return .integer(result.0) }
        }
        switch op {
        case "+": return .real(a + b)
        case "-": return .real(a - b)
        case "*": return .real(a * b)
        case "/":
            guard b != 0 else { throw EvaluationError(message: "division by zero") }
            return .real(a / b)
        case "^": return .real(pow(a, b))
        case "=": return truth(a == b)
        case "<>": return truth(a != b)
        case "<": return truth(a < b)
        case ">": return truth(a > b)
        case "<=": return truth(a <= b)
        default: return truth(a >= b)
        }
    }

    // MARK: Parsing

    struct Token: Equatable {
        enum Kind { case number, string, name, op }
        var kind: Kind
        var text: String
        var value: BasicValue?
    }

    static let wordOperators = ["AND", "DIV", "EOR", "MOD", "NOT", "OR"]
    static let pseudoVariables = ["PAGE", "TOP", "LOMEM", "HIMEM", "ERL", "ERR", "TRUE", "FALSE"]

    static func tokenise(_ source: String) throws(ParseError) -> [Token] {
        let s = Array(source.unicodeScalars)
        var tokens: [Token] = []
        var i = 0
        func isName(_ c: Unicode.Scalar) -> Bool {
            c.value < 0x80 && BasicMemory.isNameCharacter(UInt8(c.value))
        }
        while i < s.count {
            let c = s[i]
            if c == " " {
                i += 1
            } else if c == "\"" {
                var text = ""
                i += 1
                while true {
                    guard i < s.count else { throw ParseError(message: "missing \" in \(source)") }
                    if s[i] == "\"" {
                        if i + 1 < s.count && s[i + 1] == "\"" {
                            text.unicodeScalars.append("\"")
                            i += 2
                            continue
                        }
                        i += 1
                        break
                    }
                    text.unicodeScalars.append(s[i])
                    i += 1
                }
                tokens.append(Token(kind: .string, text: "\"\(text)\"", value: .string(text)))
            } else if c == "&" {
                var j = i + 1
                while j < s.count, s[j].properties.isASCIIHexDigit { j += 1 }
                guard j > i + 1, let n = UInt32(String(String.UnicodeScalarView(s[i + 1..<j])), radix: 16) else {
                    throw ParseError(message: "bad hex number in \(source)")
                }
                tokens.append(Token(kind: .number, text: String(String.UnicodeScalarView(s[i..<j])), value: .integer(Int32(bitPattern: n))))
                i = j
            } else if ("0"..."9").contains(c) || c == "." {
                var j = i
                while j < s.count, ("0"..."9").contains(s[j]) || s[j] == "." { j += 1 }
                if j < s.count, s[j] == "E" || s[j] == "e" {
                    var k = j + 1
                    if k < s.count, s[k] == "-" || s[k] == "+" { k += 1 }
                    if k < s.count, ("0"..."9").contains(s[k]) {
                        j = k
                        while j < s.count, ("0"..."9").contains(s[j]) { j += 1 }
                    }
                }
                let text = String(String.UnicodeScalarView(s[i..<j]))
                if !text.contains(where: { ".Ee".contains($0) }), let n = Int32(text) {
                    tokens.append(Token(kind: .number, text: text, value: .integer(n)))
                } else if let x = Double(text) {
                    tokens.append(Token(kind: .number, text: text, value: .real(x)))
                } else {
                    throw ParseError(message: "bad number \(text)")
                }
                i = j
            } else if isName(c) {
                // As BASIC does, a keyword at the start of a name is the
                // keyword (ORDER is OR DER).
                let rest = String(String.UnicodeScalarView(s[i...]))
                if let word = (wordOperators + pseudoVariables).first(where: { rest.hasPrefix($0) }) {
                    tokens.append(Token(kind: wordOperators.contains(word) ? .op : .name, text: word))
                    i += word.unicodeScalars.count
                    continue
                }
                var j = i
                while j < s.count, isName(s[j]) { j += 1 }
                if j < s.count, s[j] == "%" || s[j] == "$" { j += 1 }
                tokens.append(Token(kind: .name, text: String(String.UnicodeScalarView(s[i..<j]))))
                i = j
            } else {
                let two = i + 1 < s.count ? String(String.UnicodeScalarView(s[i...i + 1])) : ""
                if ["<>", "<=", ">="].contains(two) {
                    tokens.append(Token(kind: .op, text: two))
                    i += 2
                } else if "+-*/^=<>()?!$,".unicodeScalars.contains(c) {
                    tokens.append(Token(kind: .op, text: String(c)))
                    i += 1
                } else {
                    throw ParseError(message: "unexpected \(c) in \(source)")
                }
            }
        }
        return tokens
    }

    struct Parser {
        var tokens: [Token]
        var index = 0

        static let levels: [Set<String>] = [["OR", "EOR"], ["AND"], ["=", "<>", "<", ">", "<=", ">="], ["+", "-"],
                                            ["*", "/", "DIV", "MOD"], ["^"]]

        mutating func take(_ ops: Set<String>) -> String? {
            guard index < tokens.count, tokens[index].kind == .op, ops.contains(tokens[index].text) else { return nil }
            index += 1
            return tokens[index - 1].text
        }

        mutating func expect(_ op: String) throws(ParseError) {
            guard take([op]) != nil else { throw ParseError(message: "missing \(op)") }
        }

        mutating func expression() throws(ParseError) -> Node {
            try binary(level: 0)
        }

        mutating func binary(level: Int) throws(ParseError) -> Node {
            guard level < Self.levels.count else { return try unary() }
            var node = try binary(level: level + 1)
            while let op = take(Self.levels[level]) {
                node = .binary(op, node, try binary(level: level + 1))
            }
            return node
        }

        mutating func unary() throws(ParseError) -> Node {
            if let op = take(["-", "+", "NOT", "?", "!", "$"]) {
                return .unary(op, try unary())
            }
            return try primary()
        }

        mutating func primary() throws(ParseError) -> Node {
            guard index < tokens.count else { throw ParseError(message: "expression ends early") }
            let token = tokens[index]
            index += 1
            switch token.kind {
            case .number, .string:
                return .value(token.value!)
            case .name:
                if BasicExpression.pseudoVariables.contains(token.text) {
                    return .pseudo(token.text)
                }
                if take(["("]) != nil {
                    var indices = [try expression()]
                    while take([","]) != nil {
                        indices.append(try expression())
                    }
                    try expect(")")
                    return .element(token.text + "(", indices)
                }
                return .variable(token.text)
            case .op:
                guard token.text == "(" else { throw ParseError(message: "unexpected \(token.text)") }
                let node = try expression()
                try expect(")")
                return node
            }
        }
    }
}
