#if canImport(FoundationEssentials)
import FoundationEssentials
#if canImport(WASILibc)
import WASILibc
#endif
#else
import Foundation
#endif

// BBC BASIC as a debugger sees it: the interpreter in its ROM, and the
// program, variables and PROC/FN calls in memory.
//
// BASIC 2 (the B and B+) and BASIC 4 (the Masters) share their zero page:
//   &00 LOMEM  &02 VARTOP  &04 BASIC stack  &06 HIMEM  &08 ERL
//   &0A/&0B/&0C the text pointer (offset, then address)  &12 TOP
//   &16 the ON ERROR handler  &18 PAGE (high byte)  &25 GOSUBs
//   &FD the last error (from the MOS)
// and their workspace: @% to Z% at &0400, and at &0480 the heads of the
// variable lists, one per initial character from @ to z.
//
// A PROC or FN call moves the 6502 stack onto the BASIC stack (a
// byte with the old S, then the bytes above it) and runs the body with
// a fresh 6502 stack, holding the call's frame at &01F6-&01FF:
//   &01FF  the token (&F2 PROC, &A4 FN)
//   &01FE  &0A at the call, &01FD &0B, &01FC &0C
//   &01FB  how many LOCALs (and parameters) are saved
//   &01FA-&01F8  &1B, &19, &1A
//   &01F7-&01F6  the body's return address, less one
// LOCALs (and parameters) go on the BASIC stack after the moved stack,
// each the variable's address and type (4 bytes) on top of its old value.

/// A BASIC ROM, found by the code in it.
public struct BasicInterpreter: Sendable, Equatable {
    public var cpu: DebugCPU
    /// The sideways bank it's in, for the host.
    public var bank: Int?
    /// E.g. "BASIC 2".
    public var name: String
    /// The instruction each statement starts at: the statement's first
    /// character is at (&0B)+Y.
    var statement: UInt16
    /// Where a PROC or FN body returns to (in each call's frame, less one).
    var bodyReturn: UInt16
    /// BRKV: BASIC's error handler.
    var errorHandler: UInt16
    /// The ON ERROR handler when the program has none (reporting the
    /// error and stopping).
    var defaultHandler: UInt16

    /// The interpreter in a 16K ROM image at &8000, if it is one.
    static func find(_ rom: [UInt8], cpu: DebugCPU, bank: Int?) -> BasicInterpreter? {
        guard rom.count >= 0x4000, Array(rom[9..<14]) == Array("BASIC".utf8) else { return nil }
        func search(_ pattern: [UInt8?]) -> Int? {
            var i = 0
            outer: while i + pattern.count <= 0x4000 {
                for (j, byte) in pattern.enumerated() where byte != nil && rom[i + j] != byte {
                    i += 1
                    continue outer
                }
                return i
            }
            return nil
        }
        func word(_ low: Int, _ high: Int) -> UInt16 { UInt16(rom[low]) | UInt16(rom[high]) << 8 }
        // LDA (&0B),Y : CMP #' ' : BEQ (back) : CMP #&CF, the first
        // statement token.
        guard let statement = search([0xB1, 0x0B, 0xC9, 0x20, 0xF0, 0xF6, 0xC9, 0xCF]),
              // JSR (the statement loop) : PLA : STA &1A : PLA : STA &19 :
              // PLA : STA &1B : PLA
              let body = search([0x20, nil, nil, 0x68, 0x85, 0x1A, 0x68, 0x85, 0x19, 0x68, 0x85, 0x1B, 0x68]),
              // LDA #lo : STA &0202 : LDA #hi : STA &0203
              let brkv = search([0xA9, nil, 0x8D, 0x02, 0x02, 0xA9, nil, 0x8D, 0x03, 0x02]),
              // LDA #lo : STA &16 : LDA #hi : STA &17
              let handler = search([0xA9, nil, 0x85, 0x16, 0xA9, nil, 0x85, 0x17]) else { return nil }
        let version = rom[8]
        let name = switch version {
        case 0: "BASIC 1"
        case 1: "BASIC 2"
        case 2: "BASIC 3"
        case 4: "BASIC 4"
        case 0x40: "BASIC 4r32"
        default: "BASIC (version \(version))"
        }
        return BasicInterpreter(cpu: cpu, bank: bank, name: name, statement: UInt16(0x8000 + statement + 6),
                                bodyReturn: UInt16(0x8000 + body + 3), errorHandler: word(brkv + 1, brkv + 6),
                                defaultHandler: word(handler + 1, handler + 5))
    }
}

/// Where a statement is.
public struct BasicLocation: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var line: Int
    /// 1 for the first in the line; each colon starts another.
    public var statement: Int
    /// The statement's first character (or, for an error or a call, the
    /// text pointer's place in it).
    public var address: UInt16

    public init(line: Int, statement: Int = 1, address: UInt16 = 0) {
        self.line = line
        self.statement = statement
        self.address = address
    }

    public var description: String {
        statement > 1 ? "line \(line) statement \(statement)" : "line \(line)"
    }
}

/// A BASIC number or string.
public enum BasicValue: Sendable, Equatable, CustomStringConvertible {
    case integer(Int32)
    case real(Double)
    case string(String)

    /// As PRINT shows it, with strings in quotes.
    public var description: String {
        switch self {
        case .integer(let n): String(n)
        case .real(let x): Self.format(x)
        case .string(let s): "\"\(s)\""
        }
    }

    /// As PRINT shows a real by default: 9 significant figures, with an
    /// exponent if it's below 0.1 or 1E9 or more.
    static func format(_ x: Double) -> String {
        guard x != 0 else { return "0" }
        guard x.isFinite else { return x > 0 ? "1E39" : "-1E39" }
        let parts = String(format: "%.8e", x).split(separator: "e")
        guard parts.count == 2, var exponent = Int(parts[1]) else { return String(x) }
        let negative = parts[0].hasPrefix("-")
        var digits = parts[0].filter(\.isNumber)
        if digits.count > 9 {
            // %.8e rounded to 9 digits; "10.0..." when it rounded up a power.
            digits.removeLast()
            exponent += 1
        }
        while digits.count > 1 && digits.hasSuffix("0") { digits.removeLast() }
        var text: String
        if exponent >= -1 && exponent < 9 {
            if exponent < 0 {
                text = "0." + digits
            } else if digits.count > exponent + 1 {
                text = digits.prefix(exponent + 1) + "." + digits.dropFirst(exponent + 1)
            } else {
                text = digits + String(repeating: "0", count: exponent + 1 - digits.count)
            }
        } else {
            text = String(digits.prefix(1))
            if digits.count > 1 { text += "." + digits.dropFirst() }
            text += "E\(exponent)"
        }
        return (negative ? "-" : "") + text
    }

    var number: Double? {
        switch self {
        case .integer(let n): Double(n)
        case .real(let x): x
        case .string: nil
        }
    }
}

/// A variable, from BASIC's lists.
public struct BasicVariable: Sendable, Equatable {
    public enum Kind: String, Sendable { case integer, real, string }

    /// With its % or $, and ( for an array.
    public var name: String
    public var kind: Kind
    /// An array's highest index in each dimension (as DIMmed).
    public var dimensions: [Int]?
    /// A scalar's value.
    public var value: BasicValue?
    /// The value's address (an array's first element's).
    public var address: Int
    /// Saved by a LOCAL (or as a parameter) in the PROC or FN running now.
    public var isLocal = false
}

/// A PROC or FN call being run, or the main program.
public struct BasicFrame: Sendable, Equatable {
    /// "PROCname" or "FNname", or nil for the main program.
    public var name: String?
    /// Where it is: the statement running, or for a caller, the call.
    /// Nil when that's a command typed in, not a program line.
    public var location: BasicLocation?
}

/// A program line in memory.
struct BasicLine: Equatable {
    /// The &0D before it.
    var start: Int
    var number: Int
    var length: Int
    /// Its text: after the number and length, to the next &0D.
    var text: Range<Int> { start + 4..<start + length }
}

/// BASIC's memory, through one CPU.
struct BasicMemory {
    let read: (Int) -> UInt8
    let write: (Int, UInt8) -> Bool

    subscript(_ address: Int) -> UInt8 { read(address & 0xFFFF) }

    func word(_ address: Int) -> Int { Int(self[address]) | Int(self[address + 1]) << 8 }

    var page: Int { Int(self[0x18]) << 8 }
    var top: Int { word(0x12) }
    var lomem: Int { word(0x00) }
    var vartop: Int { word(0x02) }
    var himem: Int { word(0x06) }
    var gosubs: Int { Int(self[0x25]) }

    // MARK: The program

    /// The program's lines, in order.
    func lines() -> [BasicLine] {
        var lines: [BasicLine] = []
        var a = page
        while self[a] == 0x0D, self[a + 1] != 0xFF, lines.count < 0x8000, a < 0x10000 {
            let length = Int(self[a + 3])
            guard length >= 4 else { break }
            lines.append(BasicLine(start: a, number: Int(self[a + 1]) << 8 | Int(self[a + 2]), length: length))
            a += length
        }
        return lines
    }

    func bytes(_ range: Range<Int>) -> [UInt8] { range.map { self[$0] } }

    /// The statement `address` is in, in `line`.
    func location(of address: Int, in line: BasicLine) -> BasicLocation {
        var statement = 1
        var quoted = false
        var a = line.text.lowerBound
        while a < address && a < line.text.upperBound {
            let byte = self[a]
            if byte == 0x22 {
                quoted.toggle()
            } else if !quoted {
                if byte == 0x3A {
                    statement += 1
                } else if byte == 0xF4 || byte == 0xDC {
                    // REM and DATA: the rest is text.
                    break
                } else if byte == 0x8D {
                    a += 3
                }
            }
            a += 1
        }
        return BasicLocation(line: line.number, statement: statement, address: UInt16(address & 0xFFFF))
    }

    /// The name a DEF line defines (e.g. "PROCdraw"), if it's one.
    func definition(_ line: BasicLine) -> String? {
        var a = line.text.lowerBound
        while a < line.text.upperBound && self[a] == 0x20 { a += 1 }
        guard self[a] == 0xDD else { return nil }
        a += 1
        while a < line.text.upperBound && self[a] == 0x20 { a += 1 }
        let kind: String
        switch self[a] {
        case 0xF2: kind = "PROC"
        case 0xA4: kind = "FN"
        default: return nil
        }
        var name = kind
        a += 1
        while a < line.text.upperBound, Self.isNameCharacter(self[a]) {
            name.unicodeScalars.append(Unicode.Scalar(self[a]))
            a += 1
        }
        return name
    }

    static func isNameCharacter(_ c: UInt8) -> Bool {
        (0x30...0x39).contains(c) || (0x40...0x5A).contains(c) || (0x5F...0x7A).contains(c)
    }

    // MARK: PROC and FN calls

    /// The PROC/FN frame on a 6502 stack (read through `stack`, by
    /// address), if there's one.
    func frame(_ stack: (Int) -> UInt8, bodyReturn: UInt16) -> (token: UInt8, caller: Int, saved: Int)? {
        let token = stack(0x1FF)
        let ret = Int(bodyReturn) - 1
        guard token == 0xF2 || token == 0xA4, stack(0x1F7) == UInt8(ret >> 8), stack(0x1F6) == UInt8(ret & 0xFF) else {
            return nil
        }
        let caller = (Int(stack(0x1FD)) | Int(stack(0x1FC)) << 8) + max(Int(stack(0x1FE)) - 1, 0)
        return (token, caller, Int(stack(0x1FB)))
    }

    /// The size of a saved variable of `type` (as in its descriptor) at
    /// `address` on the BASIC stack, as BASIC pops it.
    func savedValueSize(type: UInt8, at address: Int) -> Int? {
        switch type {
        case 0: 1
        case 4: 4
        case 5: 5
        case 0x80, 0x81: Int(self[address]) + 1
        default: nil
        }
    }

    /// Skips `count` saved LOCALs from `address`; returns where they end
    /// and the variables' addresses, or nil if they don't look like any.
    func skipLocals(_ count: Int, from address: Int) -> (end: Int, variables: [Int])? {
        var a = address
        var variables: [Int] = []
        for _ in 0..<count {
            let variable = word(a)
            guard variable >= 0x0400, variable < 0x10000, let size = savedValueSize(type: self[a + 2], at: a + 4) else {
                return nil
            }
            variables.append(variable)
            a += 4 + size
        }
        return a <= himem ? (a, variables) : nil
    }

    /// A moved 6502 stack at `address`: where it ends, and its bytes (by
    /// their stack address).
    func savedStack(at address: Int) -> (end: Int, read: (Int) -> UInt8)? {
        let s = Int(self[address])
        let end = address + 1 + 0xFF - s
        guard end <= himem else { return nil }
        return (end, { a in a & 0xFF > s ? self[address + (a & 0xFF) - s] : 0 })
    }

    /// The innermost call's saved stack's address (its depth: lower is
    /// deeper), or for the main program, past the top of memory.
    func frameKey(liveStack: (Int) -> UInt8, bodyReturn: UInt16) -> Int {
        guard let frame = frame(liveStack, bodyReturn: bodyReturn),
              let locals = skipLocals(frame.saved, from: word(0x04)) else { return 0x10000 }
        return locals.end
    }

    /// The calls being run, innermost first: each one's kind (the PROC or
    /// FN token), where it was called from and its LOCALs' addresses; and
    /// whether they were followed all the way out to the main program.
    /// `valuesOnTop` if an expression's values can be on the BASIC stack
    /// (stopped part way through a statement).
    func calls(liveStack: (Int) -> UInt8, bodyReturn: UInt16, valuesOnTop: Bool = false)
        -> (calls: [(token: UInt8, caller: Int, locals: [Int])], complete: Bool) {
        var calls: [(token: UInt8, caller: Int, locals: [Int])] = []
        var stack = liveStack
        var a = word(0x04)
        var valuesBelow = valuesOnTop
        while let frame = frame(stack, bodyReturn: bodyReturn) {
            guard calls.count < 256,
                  let start = valuesBelow ? localsStart(frame.saved, from: a, bodyReturn: bodyReturn) : a,
                  let locals = skipLocals(frame.saved, from: start), let saved = savedStack(at: locals.end) else {
                calls.append((frame.token, frame.caller, []))
                return (calls, false)
            }
            calls.append((frame.token, frame.caller, locals.variables))
            stack = saved.read
            a = saved.end
            // Calling an FN can leave the caller's expression's values on
            // the BASIC stack, between the two.
            valuesBelow = frame.token == 0xA4
        }
        return (calls, true)
    }

    /// Where a call's `count` LOCALs start, at or after `address` (with
    /// values of unknown sizes before them): where they lead to a saved
    /// stack with another call's frame, or the main program's (a return
    /// address into the ROM on top).
    func localsStart(_ count: Int, from address: Int, bodyReturn: UInt16) -> Int? {
        (address..<max(address, min(address + 0x100, himem))).first { s in
            guard let locals = skipLocals(count, from: s), let next = savedStack(at: locals.end) else { return false }
            return frame(next.read, bodyReturn: bodyReturn) != nil
                || self[locals.end] < 0xFF && (0x80...0xBF).contains(next.read(0x1FF))
        }
    }

    // MARK: Variables

    /// Every variable (not PROCs and FNs), @% to Z% first.
    func variables() -> [BasicVariable] {
        var variables: [BasicVariable] = []
        for c in 0x40...0x5A {
            let name = String(Unicode.Scalar(UInt8(c))) + "%"
            let address = 0x0400 + (c - 0x40) * 4
            variables.append(BasicVariable(name: name, kind: .integer, value: integer(at: address), address: address))
        }
        for c in 0x40...0x7A {
            var entry = word(0x0480 + (c - 0x40) * 2)
            var seen = 0
            while entry >= 0x0100, seen < 4096 {
                seen += 1
                var name = String(Unicode.Scalar(UInt8(c)))
                var a = entry + 2
                while self[a] != 0, a < entry + 2 + 255 {
                    name.unicodeScalars.append(Unicode.Scalar(self[a]))
                    a += 1
                }
                if let variable = variable(name, valueAt: a + 1) {
                    variables.append(variable)
                }
                entry = word(entry)
            }
        }
        return variables
    }

    func variable(_ name: String, valueAt a: Int) -> BasicVariable? {
        let array = name.hasSuffix("(")
        let base = array ? String(name.dropLast()) : name
        let kind: BasicVariable.Kind = base.hasSuffix("%") ? .integer : base.hasSuffix("$") ? .string : .real
        guard array else {
            return BasicVariable(name: name, kind: kind, value: value(kind, at: a), address: a)
        }
        // An array: 2n+1, then n dimension sizes (each its highest index
        // plus one), then the elements.
        let header = Int(self[a])
        guard header >= 3, header & 1 == 1 else { return nil }
        let dimensions = (0..<(header - 1) / 2).map { word(a + 1 + 2 * $0) - 1 }
        return BasicVariable(name: name, kind: kind, dimensions: dimensions, address: a + header)
    }

    func elementSize(_ kind: BasicVariable.Kind) -> Int { kind == .real ? 5 : 4 }

    /// An array's element, if the indices are in range.
    func element(_ array: BasicVariable, _ indices: [Int]) -> BasicValue? {
        guard let dimensions = array.dimensions, indices.count == dimensions.count,
              let offset = elementOffset(dimensions, indices) else { return nil }
        return value(array.kind, at: array.address + offset * elementSize(array.kind))
    }

    func elementOffset(_ dimensions: [Int], _ indices: [Int]) -> Int? {
        var offset = 0
        for (index, highest) in zip(indices, dimensions) {
            guard (0...highest).contains(index) else { return nil }
            offset = offset * (highest + 1) + index
        }
        return offset
    }

    func value(_ kind: BasicVariable.Kind, at a: Int) -> BasicValue {
        switch kind {
        case .integer: integer(at: a)
        case .real: .real(real(at: a))
        case .string: .string(string(descriptorAt: a))
        }
    }

    func integer(at a: Int) -> BasicValue {
        .integer(Int32(bitPattern: UInt32(self[a]) | UInt32(self[a + 1]) << 8 | UInt32(self[a + 2]) << 16 | UInt32(self[a + 3]) << 24))
    }

    /// A 5-byte real: the exponent (excess &80), then the mantissa, most
    /// significant byte first, its top bit the sign (the 1 it stands for
    /// is implied).
    func real(at a: Int) -> Double {
        let exponent = Int(self[a])
        guard exponent != 0 else { return 0 }
        let mantissa = (UInt32(self[a + 1]) | 0x80) << 24 | UInt32(self[a + 2]) << 16 | UInt32(self[a + 3]) << 8 | UInt32(self[a + 4])
        let magnitude = Double(mantissa) * pow(2, Double(exponent - 0x80 - 32))
        return self[a + 1] & 0x80 != 0 ? -magnitude : magnitude
    }

    static func encodeReal(_ x: Double) -> [UInt8] {
        guard x != 0, x.isFinite else { return [0, 0, 0, 0, 0] }
        var exponent = Int(x.magnitude.exponent) + 1
        var mantissa = (x.magnitude.significand * pow(2, 31)).rounded()
        if mantissa >= pow(2, 32) {
            mantissa /= 2
            exponent += 1
        }
        guard exponent + 0x80 > 0 else { return [0, 0, 0, 0, 0] }
        let m = UInt32(min(mantissa, Double(UInt32.max)))
        let top = UInt8(m >> 24) & 0x7F | (x < 0 ? 0x80 : 0)
        return [UInt8(min(exponent + 0x80, 0xFF)), top, UInt8(m >> 16 & 0xFF), UInt8(m >> 8 & 0xFF), UInt8(m & 0xFF)]
    }

    /// A string variable's text, from its descriptor: address, space
    /// allocated, length.
    func string(descriptorAt a: Int) -> String {
        let address = word(a)
        let length = Int(self[a + 3])
        return Self.text(bytes(address..<address + length))
    }

    /// A string at an address, to its CR ($address).
    func string(at address: Int) -> String {
        var bytes: [UInt8] = []
        while bytes.count < 255, self[address + bytes.count] != 0x0D { bytes.append(self[address + bytes.count]) }
        return Self.text(bytes)
    }

    static func text(_ bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }

    /// Writes a scalar's value; false if it's the wrong kind, or a string
    /// longer than the space it has.
    func set(_ variable: BasicVariable, to value: BasicValue) -> Bool {
        set(variable.kind, at: variable.address, to: value)
    }

    func set(_ kind: BasicVariable.Kind, at a: Int, to value: BasicValue) -> Bool {
        var bytes: [UInt8]
        var at = a
        switch (kind, value) {
        case (.integer, .integer(let n)):
            bytes = withUnsafeBytes(of: n.littleEndian, Array.init)
        case (.integer, .real(let x)):
            guard x.rounded(.towardZero) >= Double(Int32.min), x.rounded(.towardZero) <= Double(Int32.max) else { return false }
            bytes = withUnsafeBytes(of: Int32(x.rounded(.towardZero)).littleEndian, Array.init)
        case (.real, _):
            guard let x = value.number else { return false }
            bytes = Self.encodeReal(x)
        case (.string, .string(let s)):
            let text = s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
            guard text.count <= Int(self[a + 2]) else { return false }
            let address = word(a)
            for (i, byte) in text.enumerated() where !write(address + i, byte) { return false }
            at = a + 3
            bytes = [UInt8(text.count)]
        default:
            return false
        }
        for (i, byte) in bytes.enumerated() where !write(at + i, byte) { return false }
        return true
    }
}
