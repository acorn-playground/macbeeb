#if !canImport(CoreGraphics)
import CCairo
import Foundation

/// A page drawn to pixels (on Linux, where there's no CGImage): straight
/// 0xAARRGGBB, row by row from the top.
public struct PageImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt32]
}

// MARK: Drawing (Cairo, on Linux; the Mac's is Core Graphics)

extension Printout {
    /// Draws page `index` into `cairo` (a `cairo_t`), whose origin is the
    /// page's top-left and whose size is the paper's (in points). `font` is
    /// the 8×8 character set (characters 32-127, 8 bytes each) for dot
    /// matrix. The page is laid out exactly as the Mac's.
    public func draw(page index: Int, in cairo: OpaquePointer, font: [UInt8]) {
        let size = settings.paper.size
        let height = Double(size.height)
        cairo_save(cairo)
        defer { cairo_restore(cairo) }
        cairo_set_source_rgb(cairo, 1, 1, 1)
        cairo_rectangle(cairo, 0, 0, Double(size.width), height)
        cairo_fill(cairo)
        let charWidth = 72 / Self.pitch
        let lineHeight = 72 / Self.lineSpacing
        // Centre 8 inches of text across the paper; a third of an inch down.
        let left = max(18, (Double(size.width) - 80 * charWidth) / 2)
        // (The Mac's is measured up from the bottom: y here is height - y.)
        let top = 24.0
        let ink = (0.12, 0.12, 0.16)
        cairo_set_source_rgb(cairo, ink.0, ink.1, ink.2)
        for (row, line) in pages[index].enumerated() {
            let baseline = top + Double(row + 1) * lineHeight - lineHeight * 0.25
            // The line as text: what's seen in the clean style, and under the
            // dots (all but invisibly) in the dot-matrix one, so a PDF can
            // be searched and copied from either way.
            let fitting = Int((Double(size.width) - 8 - left) / charWidth)
            drawText(Array(line.prefix(fitting)), at: (left, baseline), size: charWidth / 0.6,
                     visible: settings.style == .clean, ink: ink, in: cairo)
            for (column, item) in line.enumerated() {
                guard let item else { continue }
                let x = left + Double(column) * charWidth
                guard x < Double(size.width) - 8 else { break }
                switch settings.style {
                case .clean:
                    break
                case .dotMatrix:
                    drawDots(item.code, bold: item.bold, font: font, origin: (x, baseline), width: charWidth,
                             height: lineHeight * 0.75, in: cairo)
                }
                if item.underline {
                    cairo_rectangle(cairo, x, baseline + 1.0, charWidth, 0.6)
                    cairo_fill(cairo)
                }
            }
        }
        if settings.paper == .fanfold {
            // The tractor holes down each side.
            cairo_set_source_rgb(cairo, 0.85, 0.85, 0.85)
            var y = 9.0
            while y < height {
                for x in [9.0, Double(size.width) - 9] {
                    cairo_new_sub_path(cairo)
                    cairo_arc(cairo, x, height - y, 3, 0, 2 * Double.pi)
                    cairo_fill(cairo)
                }
                y += 36
            }
        }
    }

    /// The line's characters, each in its column (whatever the monospaced
    /// font's own advance).
    private func drawText(_ line: [Character?], at point: (x: Double, y: Double), size: Double, visible: Bool,
                          ink: (Double, Double, Double), in cairo: OpaquePointer) {
        guard line.contains(where: { $0 != nil && $0?.code != 0x20 }) else { return }
        cairo_save(cairo)
        defer { cairo_restore(cairo) }
        // Cairo leaves out what's fully transparent, so "invisible" is
        // nearly so: still text in a PDF, but not to be seen.
        cairo_set_source_rgba(cairo, ink.0, ink.1, ink.2, visible ? 1 : 1.0 / 255)
        cairo_set_font_size(cairo, size)
        let charWidth = 72 / Self.pitch
        for bold in [false, true] {
            cairo_select_font_face(cairo, "Courier", CAIRO_FONT_SLANT_NORMAL,
                                   bold ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL)
            for (column, item) in line.enumerated() {
                guard let item, item.code != 0x20, item.bold == bold else { continue }
                let scalar = UnicodeScalar(item.code < 128 ? item.code : 0x3F)
                cairo_move_to(cairo, point.x + Double(column) * charWidth, point.y)
                cairo_show_text(cairo, String(scalar))
            }
        }
    }

    private func drawDots(_ code: UInt8, bold: Bool, font: [UInt8], origin: (x: Double, y: Double), width: Double,
                          height: Double, in cairo: OpaquePointer) {
        let index = Int(code & 0x7F) - 32
        guard index >= 0, index * 8 + 8 <= font.count else { return }
        let dotX = width / 8, dotY = height / 8
        let radius = min(dotX, dotY) * (bold ? 0.62 : 0.5)
        for row in 0..<8 {
            let bits = font[index * 8 + row]
            guard bits != 0 else { continue }
            for bit in 0..<8 where bits & (0x80 >> bit) != 0 {
                let cx = origin.x + (Double(bit) + 0.5) * dotX
                // Row 0 at the top, the bottom row on the baseline.
                let cy = origin.y - (Double(7 - row) + 0.5) * dotY + dotY
                cairo_new_sub_path(cairo)
                cairo_arc(cairo, cx, cy, radius, 0, 2 * Double.pi)
                if bold {
                    cairo_new_sub_path(cairo)
                    cairo_arc(cairo, cx + dotX * 0.35, cy, radius, 0, 2 * Double.pi)
                }
                cairo_fill(cairo)
            }
        }
    }

    /// The whole printout as a PDF.
    public func pdf(font: [UInt8], title: String) -> Data {
        let size = settings.paper.size
        let output = PDFOutput()
        let unmanaged = Unmanaged.passRetained(output)
        defer { unmanaged.release() }
        let surface = cairo_pdf_surface_create_for_stream({ closure, bytes, length in
            guard let closure, let bytes else { return CAIRO_STATUS_WRITE_ERROR }
            Unmanaged<PDFOutput>.fromOpaque(closure).takeUnretainedValue().data.append(bytes, count: Int(length))
            return CAIRO_STATUS_SUCCESS
        }, unmanaged.toOpaque(), Double(size.width), Double(size.height))
        cairo_pdf_surface_set_metadata(surface, CAIRO_PDF_METADATA_TITLE, title)
        cairo_pdf_surface_set_metadata(surface, CAIRO_PDF_METADATA_CREATOR, "MacBeeb")
        let cairo = cairo_create(surface)!
        for index in pages.indices {
            draw(page: index, in: cairo, font: font)
            cairo_show_page(cairo)
        }
        cairo_destroy(cairo)
        cairo_surface_finish(surface)
        cairo_surface_destroy(surface)
        return output.data
    }

    /// A page as an image, `scale` pixels per point.
    public func image(page index: Int, scale: Double, font: [UInt8]) -> PageImage? {
        let size = settings.paper.size
        let width = Int(Double(size.width) * scale), height = Int(Double(size.height) * scale)
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(width), Int32(height)) else { return nil }
        defer { cairo_surface_destroy(surface) }
        let cairo = cairo_create(surface)!
        cairo_scale(cairo, scale, scale)
        draw(page: index, in: cairo, font: font)
        cairo_destroy(cairo)
        cairo_surface_flush(surface)
        guard let base = cairo_image_surface_get_data(surface) else { return nil }
        let stride = Int(cairo_image_surface_get_stride(surface))
        var pixels = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = UnsafeRawPointer(base + y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                // The page is opaque, so premultiplied is straight.
                pixels[y * width + x] = row[x]
            }
        }
        return PageImage(width: width, height: height, pixels: pixels)
    }
}

private final class PDFOutput {
    var data = Data()
}
#endif
