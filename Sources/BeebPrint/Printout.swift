#if canImport(CoreGraphics)
import CoreGraphics
import CoreText
#endif
import Foundation

/// How a job's put on paper.
public struct PrintSettings: Codable, Sendable, Hashable {
    public enum Paper: String, Codable, Sendable, CaseIterable {
        case a4, letter, fanfold

        public var displayName: String {
            switch self {
            case .a4: "A4"
            case .letter: "US Letter"
            case .fanfold: "Fanfold (11 × 9.5 in)"
            }
        }

        /// Points.
        public var size: CGSize {
            switch self {
            case .a4: CGSize(width: 595.28, height: 841.89)
            case .letter: CGSize(width: 612, height: 792)
            case .fanfold: CGSize(width: 684, height: 792)
            }
        }
    }

    public enum Style: String, Codable, Sendable, CaseIterable {
        /// Crisp type.
        case clean
        /// Dots, as a dot-matrix printer makes them (in the BBC's own
        /// characters: not a reproduction of any printer's font).
        case dotMatrix

        public var displayName: String {
            switch self {
            case .clean: "Clean"
            case .dotMatrix: "Dot Matrix"
            }
        }
    }

    public var paper = Paper.a4
    public var style = Style.dotMatrix
    /// A carriage return also feeds a line (as most printers' switches are
    /// set for the BBC, which doesn't send line feeds by default).
    public var autoLineFeed = true

    public init() {}
}

/// A job laid out on pages: 10 characters an inch, 6 lines an inch, 66
/// lines a page (11 inches, on any paper), as a printer would. Text, CR,
/// LF, tab, backspace and form feed are understood, and Epson's bold and
/// underline; other control codes are kept in the job and listed in
/// `unsupported`, not guessed.
public struct Printout: Sendable {
    public struct Character: Sendable, Equatable {
        public var code: UInt8
        public var bold = false
        public var underline = false
    }

    /// Each page's lines; each line's characters by column (nil: nothing
    /// printed there).
    public private(set) var pages: [[[Character?]]] = []
    /// The codes the renderer doesn't draw, and how often.
    public private(set) var unsupported: [String: Int] = [:]
    public let settings: PrintSettings

    public static let linesPerPage = 66
    public static let columns = 132
    /// Characters and lines an inch.
    static let pitch = 10.0, lineSpacing = 6.0

    public init(_ bytes: [UInt8], settings: PrintSettings = PrintSettings()) {
        self.settings = settings
        var page: [[Character?]] = []
        var line: [Character?] = []
        var column = 0
        var bold = false, underline = false
        var lastWasCR = false
        var index = 0

        func newLine() {
            page.append(line)
            line = []
            column = 0
            if page.count >= Self.linesPerPage {
                pages.append(page)
                page = []
            }
        }
        func put(_ code: UInt8) {
            guard column < Self.columns else { return }
            while line.count <= column { line.append(nil) }
            if let existing = line[column], existing.code != 0x20 {
                // Overstrike (backspace and print): keep the darker.
                line[column] = Character(code: code == 0x20 ? existing.code : code,
                                         bold: bold || existing.bold || code == existing.code,
                                         underline: underline || existing.underline)
            } else {
                line[column] = Character(code: code, bold: bold, underline: underline)
            }
            column += 1
        }
        func note(_ name: String) { unsupported[name, default: 0] += 1 }

        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            defer { lastWasCR = byte == 13 }
            switch byte {
            case 32...126, 160...255:
                put(byte & 0x7F < 32 ? 0x20 : byte)
            case 13:
                if settings.autoLineFeed { newLine() } else { column = 0 }
            case 10:
                if !(settings.autoLineFeed && lastWasCR) { newLine() }
            case 12:
                if !line.isEmpty { page.append(line); line = [] }
                column = 0
                pages.append(page)
                page = []
            case 9:
                column = min(Self.columns, (column / 8 + 1) * 8)
            case 8:
                column = max(0, column - 1)
            case 27:
                guard index < bytes.count else { break }
                let command = bytes[index]
                index += 1
                switch command {
                case UInt8(ascii: "E"): bold = true
                case UInt8(ascii: "F"): bold = false
                case UInt8(ascii: "-"):
                    if index < bytes.count { underline = bytes[index] & 1 != 0; index += 1 }
                case UInt8(ascii: "@"):
                    bold = false; underline = false
                default:
                    // Most Epson commands take a parameter byte or none; the
                    // rest are just skipped, and noted.
                    note("ESC \(Self.describe(command))")
                    if let count = Self.parameterCounts[command] { index += count }
                }
            case 0, 127:
                break
            default:
                note(Self.describe(byte))
            }
        }
        if !line.isEmpty { page.append(line) }
        if !page.isEmpty || pages.isEmpty { pages.append(page) }
    }

    static let parameterCounts: [UInt8: Int] = [
        UInt8(ascii: "A"): 1, UInt8(ascii: "3"): 1, UInt8(ascii: "J"): 1, UInt8(ascii: "Q"): 1, UInt8(ascii: "l"): 1,
        UInt8(ascii: "C"): 1, UInt8(ascii: "N"): 1, UInt8(ascii: "R"): 1, UInt8(ascii: "S"): 1, UInt8(ascii: "W"): 1,
        UInt8(ascii: "!"): 1, UInt8(ascii: "x"): 1, UInt8(ascii: "k"): 1, UInt8(ascii: "a"): 1,
    ]

    static func describe(_ byte: UInt8) -> String {
        if byte >= 32 && byte < 127 { return "'\(Swift.Character(UnicodeScalar(byte)))'" }
        return String(format: "&%02X", byte)
    }

    public var pageCount: Int { pages.count }

    /// The page's text, for search and checks.
    public func text(page: Int) -> String {
        pages[page].map { line in
            String(line.map { $0.map { Swift.Character(UnicodeScalar($0.code)) } ?? " " }).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    // MARK: Drawing (Core Graphics; on Linux, Cairo: see Printout+Cairo.swift)

    #if canImport(CoreGraphics)

    /// Draws page `index` into `context`, whose origin is the page's
    /// bottom-left and whose size is the paper's (in points). `font` is the
    /// 8×8 character set (characters 32-127, 8 bytes each) for dot matrix.
    public func draw(page index: Int, in context: CGContext, font: [UInt8]) {
        let size = settings.paper.size
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let charWidth = 72 / Self.pitch
        let lineHeight = 72 / Self.lineSpacing
        // Centre 8 inches of text across the paper; a third of an inch down.
        let left = max(18, (size.width - 80 * charWidth) / 2)
        let top = size.height - 24
        let ink = CGColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
        context.setFillColor(ink)
        context.setStrokeColor(ink)
        let ctFont = CTFontCreateWithName("Courier" as CFString, charWidth / 0.6, nil)
        let boldFont = CTFontCreateCopyWithSymbolicTraits(ctFont, 0, nil, .boldTrait, .boldTrait) ?? ctFont
        for (row, line) in pages[index].enumerated() {
            let baseline = top - Double(row + 1) * lineHeight + lineHeight * 0.25
            // The line as text: what's seen in the clean style, and under the
            // dots (invisibly) in the dot-matrix one, so a PDF can be
            // searched and copied from either way.
            let fitting = Int((size.width - 8 - left) / charWidth)
            drawText(Array(line.prefix(fitting)), regular: ctFont, bold: boldFont, at: CGPoint(x: left, y: baseline),
                     visible: settings.style == .clean, ink: ink, in: context)
            for (column, item) in line.enumerated() {
                guard let item else { continue }
                let x = left + Double(column) * charWidth
                guard x < size.width - 8 else { break }
                switch settings.style {
                case .clean:
                    break
                case .dotMatrix:
                    drawDots(item.code, bold: item.bold, font: font, origin: CGPoint(x: x, y: baseline), width: charWidth,
                             height: lineHeight * 0.75, in: context)
                }
                if item.underline {
                    context.fill(CGRect(x: x, y: baseline - 1.6, width: charWidth, height: 0.6))
                }
            }
        }
        if settings.paper == .fanfold {
            // The tractor holes down each side.
            context.setFillColor(CGColor(gray: 0.85, alpha: 1))
            var y = 9.0
            while y < size.height {
                for x in [9.0, size.width - 9] {
                    context.fillEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
                }
                y += 36
            }
        }
    }

    private func drawText(_ line: [Character?], regular: CTFont, bold: CTFont, at point: CGPoint, visible: Bool,
                          ink: CGColor, in context: CGContext) {
        guard line.contains(where: { $0 != nil && $0?.code != 0x20 }) else { return }
        let text = NSMutableAttributedString()
        for item in line {
            let code = item?.code ?? 0x20
            let scalar = UnicodeScalar(code < 128 ? code : 0x3F)
            text.append(NSAttributedString(string: String(scalar), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): item?.bold == true ? bold : regular,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
            ]))
        }
        let ctLine = CTLineCreateWithAttributedString(text)
        context.saveGState()
        context.setTextDrawingMode(visible ? .fill : .invisible)
        context.textPosition = point
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }

    private func drawDots(_ code: UInt8, bold: Bool, font: [UInt8], origin: CGPoint, width: Double, height: Double,
                          in context: CGContext) {
        let index = Int(code & 0x7F) - 32
        guard index >= 0, index * 8 + 8 <= font.count else { return }
        let dotX = width / 8, dotY = height / 8
        let radius = min(dotX, dotY) * (bold ? 0.62 : 0.5)
        for row in 0..<8 {
            let bits = font[index * 8 + row]
            guard bits != 0 else { continue }
            for bit in 0..<8 where bits & (0x80 >> bit) != 0 {
                let cx = origin.x + (Double(bit) + 0.5) * dotX
                let cy = origin.y + (Double(7 - row) + 0.5) * dotY - dotY
                context.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
                if bold {
                    context.fillEllipse(in: CGRect(x: cx - radius + dotX * 0.35, y: cy - radius, width: radius * 2, height: radius * 2))
                }
            }
        }
    }

    /// The whole printout as a PDF.
    public func pdf(font: [UInt8], title: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: settings.paper.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box,
                                      [kCGPDFContextTitle: title, kCGPDFContextCreator: "MacBeeb"] as CFDictionary) else {
            return Data()
        }
        for index in pages.indices {
            context.beginPDFPage(nil)
            draw(page: index, in: context, font: font)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A page as an image, `scale` pixels per point.
    public func image(page index: Int, scale: Double, font: [UInt8]) -> CGImage? {
        let size = settings.paper.size
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        draw(page: index, in: context, font: font)
        return context.makeImage()
    }
    #endif

}
