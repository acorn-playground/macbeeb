import BeebLibrary
import BeebROMs
import CGtk
import Foundation

// The welcome screen's pictures, drawn as the Mac's are: a BBC Micro's
// screen typing things to try, the function-key strip's colours, the
// models, some of the library's covers fanned out, and BBC Micros on an
// Econet cable with frames running along it. They're still when the
// desktop asks for no animations.

/// Whether the desktop's style is dark (libadwaita's style manager).
@MainActor
private var isDark: Bool {
    adw_style_manager_get_dark(adw_style_manager_get_default()) != 0
}

/// Redraws `area` whenever `frame` (of the time, in seconds) changes, for
/// as long as it's shown, unless animations are off.
@MainActor
private func animate(_ area: DrawingArea, _ frame: @escaping @MainActor (Double) -> Int) {
    guard PreferencesUI.animationsEnabled else { return }
    var last = Int.min
    area.onTick { _ in
        let now = frame(Date().timeIntervalSinceReferenceDate)
        if now != last {
            last = now
            area.queueDraw()
        }
        return true
    }
}

/// The time to draw: now, or (with animations off) a moment worth seeing.
@MainActor
private func drawingTime(still: Double) -> Double {
    PreferencesUI.animationsEnabled ? Date().timeIntervalSinceReferenceDate : still
}

// MARK: The BBC's screen

/// A BBC Micro's screen at power on, in its own font, typing things to
/// try.
@MainActor
enum BootScreenArt {
    static let commands = ["CHAIN \"ELITE\"", "*CLUSTER", "MODE 2", "*NET", "PRINT \"HELLO\"", "*ROMS", "*IWORD", "RUN"]
    /// The OS 1.20 font: 8 bytes a character from space.
    static let font: [UInt8] = Array(BeebROMs.data(.os12).prefix(96 * 8))
    /// Room around the bezel for its shadow and glow.
    static let margin = 16.0

    static func make() -> Widget {
        let width = 384 + Int32(margin * 2), height = 240 + Int32(margin * 2)
        let area = DrawingArea(width: width, height: height) { cairo, width, height in
            draw(cairo, width: width, height: height, time: drawingTime(still: 4 * 3 + 3.5))
        }
        area.size(width: width, height: height)
        area.accessibleLabel("A BBC Micro’s screen at power on: BBC Computer 32K, Acorn DFS, BASIC")
        animate(area) { time in
            // What changes: the command, the letters typed, the cursor.
            let lines = lines(at: time)
            return lines.last.map { $0.hashValue } ?? 0
        }
        return area
    }

    /// The boot text, then a command being typed (a few seconds each),
    /// with the cursor flashing.
    static func lines(at time: Double) -> [String] {
        let period = 4.0
        let index = Int(time / period) % commands.count
        let into = time.truncatingRemainder(dividingBy: period)
        let command = commands[index]
        let typed = String(command.prefix(max(0, Int((into - 0.6) * 9))))
        let cursor = Int(time * 2.5) % 2 == 0 ? "_" : " "
        return ["BBC Computer 32K", "", "Acorn DFS", "", "BASIC", "", ">" + typed + cursor]
            .map { String($0.prefix(19)) }
    }

    static func draw(_ g: Cairo, width: Double, height: Double, time: Double) {
        let m = margin
        let bezel = (x: m, y: m, width: width - 2 * m, height: height - 2 * m)
        // The glow, then the shadow under the bezel.
        for step in 0..<6 {
            let grow = Double(step) * 3 + 3
            g.color(0.2, 0.9, 0.4, 0.022)
            g.roundedRectangle(bezel.x - grow, bezel.y - grow, bezel.width + 2 * grow, bezel.height + 2 * grow,
                               radius: 20 + grow)
            g.fill()
        }
        for step in 0..<5 {
            let grow = Double(step) * 2
            g.color(0, 0, 0, isDark ? 0.10 : 0.05)
            g.roundedRectangle(bezel.x - grow, bezel.y + 6 - grow / 2, bezel.width + 2 * grow, bezel.height + grow,
                               radius: 20 + grow)
            g.fill()
        }
        g.color(0.16, 0.16, 0.16)
        g.roundedRectangle(bezel.x, bezel.y, bezel.width, bezel.height, radius: 20)
        g.fill()

        // The screen.
        let screen = (x: bezel.x + 10, y: bezel.y + 10, width: bezel.width - 20, height: bezel.height - 20)
        g.save()
        g.roundedRectangle(screen.x, screen.y, screen.width, screen.height, radius: 14)
        g.clip()
        g.color(0.02, 0.03, 0.025)
        g.paint()
        let lines = lines(at: time)
        let columns = 19.0
        let pixel = floor(screen.width * 0.86 / (columns * 8))
        let lineHeight = 8 * pixel * 1.5
        let originX = screen.x + (screen.width - columns * 8 * pixel) / 2
        let originY = screen.y + (screen.height - Double(lines.count) * lineHeight) / 2
        g.color(0.92, 1, 0.92)
        for (row, line) in lines.enumerated() {
            for (column, character) in line.unicodeScalars.enumerated() {
                glyph(Int(character.value), x: originX + Double(column) * 8 * pixel, y: originY + Double(row) * lineHeight,
                      pixel: pixel, g)
            }
        }
        g.fill()
        // Scan lines.
        g.color(0, 0, 0, 0.22)
        var y = screen.y
        while y < screen.y + screen.height {
            g.rectangle(screen.x, y, screen.width, 1)
            y += 3
        }
        g.fill()
        g.restore()
        g.color(1, 1, 1, 0.14)
        g.roundedRectangle(screen.x + 0.5, screen.y + 0.5, screen.width - 1, screen.height - 1, radius: 14)
        g.stroke(width: 1)
    }

    /// A character's pixels, as rectangles to fill.
    private static func glyph(_ character: Int, x: Double, y: Double, pixel: Double, _ g: Cairo) {
        guard (32..<128).contains(character), font.count >= 96 * 8 else { return }
        let start = (character - 32) * 8
        for row in 0..<8 {
            let bits = font[start + row]
            for bit in 0..<8 where bits & (0x80 >> bit) != 0 {
                g.rectangle(x + Double(bit) * pixel, y + Double(row) * pixel, pixel, pixel)
            }
        }
    }
}

// MARK: The function-key strip

/// The BBC Micro's function-key strip colours, as a rule under the title.
@MainActor
enum TeletextStripeArt {
    static let colours: [UInt32] = [0xE01B24, 0xFF7800, 0xF6D32D, 0x33D17A, 0x33C7DE, 0x3584E4, 0x9141AC]

    static func make() -> Widget {
        let count = Double(colours.count)
        let width = Int32(count * 34 + (count - 1) * 4)
        let area = DrawingArea(width: width, height: 6) { g, _, _ in
            for (index, colour) in colours.enumerated() {
                let x = Double(index) * 38
                // Each a little lighter at the top, as the Mac's gradients.
                g.color(hex: colour)
                g.roundedRectangle(x, 0, 34, 6, radius: 3)
                g.fill()
                g.color(1, 1, 1, 0.18)
                g.roundedRectangle(x, 0, 34, 3, radius: 1.5)
                g.fill()
            }
        }
        area.size(width: width, height: 6).align(horizontal: GTK_ALIGN_START)
        macbeeb_preferences_accessible_hidden(area.widget)
        return area
    }
}

// MARK: The models

/// The models, as chips, under a computer.
@MainActor
enum ModelChipsArt {
    static func make() -> Widget {
        let chips = Box(.horizontal, spacing: 6)
        for model in ["Model B", "B+", "Master 128", "Compact"] {
            chips.append(Label(model, style: "macbeeb-welcome-chip"))
        }
        chips.align(horizontal: GTK_ALIGN_CENTER)
        let art = Box(.vertical, spacing: 10) {
            Icon("computer-symbolic", size: 46).opacity(0.9)
            chips
        }
        art.align(vertical: GTK_ALIGN_CENTER)
        let backdrop = Bin(art)
        macbeeb_preferences_accessible_hidden(backdrop.widget)
        return backdrop
    }
}

// MARK: The covers

/// Some of the library's covers, fanned out.
@MainActor
enum CoverFanArt {
    static let names = ["chuckie-egg", "repton", "elite-copro", "exile-64k", "citadel"]
    static let images: [PlatformImage] = names.compactMap { name in
        BeebLibrary.bundle.url(forResource: name, withExtension: "jpg", subdirectory: "Covers")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(PlatformImage.init(encoded:))
    }

    static func make() -> Widget {
        let area = DrawingArea(height: 124) { g, width, height in
            draw(g, width: width, height: height)
        }
        area.expand(horizontal: true)
        macbeeb_preferences_accessible_hidden(area.widget)
        return area
    }

    static func draw(_ g: Cairo, width: Double, height: Double) {
        let images = images
        let middle = Double(images.count - 1) / 2
        let coverWidth = 70.0, coverHeight = 96.0
        for (index, image) in images.enumerated() {
            let place = Double(index) - middle
            g.save()
            // Centred, turned about its foot, then moved out along the fan.
            g.translate(width / 2 + place * 40, height / 2 + abs(place) * 7 + 10 + coverHeight / 2)
            cairo_rotate(g.context, place * 9 * .pi / 180)
            g.translate(-coverWidth / 2, -coverHeight)
            // A soft shadow.
            for step in 0..<4 {
                let grow = Double(step) * 1.5
                g.color(0, 0, 0, 0.09)
                g.roundedRectangle(-grow, 3 - grow, coverWidth + 2 * grow, coverHeight + 2 * grow, radius: 5 + grow)
                g.fill()
            }
            g.roundedRectangle(0, 0, coverWidth, coverHeight, radius: 5)
            g.clip()
            // Filling the cover's shape (as aspect fill), centred.
            let scale = max(coverWidth / Double(image.width), coverHeight / Double(image.height))
            let drawnWidth = Double(image.width) * scale, drawnHeight = Double(image.height) * scale
            g.image(image, x: (coverWidth - drawnWidth) / 2, y: (coverHeight - drawnHeight) / 2,
                    width: drawnWidth, height: drawnHeight)
            g.restore()
        }
    }
}

// MARK: Econet

/// BBC Micros on a cable, with frames running along it.
@MainActor
enum EconetArt {
    static func make() -> Widget {
        let area = DrawingArea(height: 124) { g, width, height in
            draw(g, width: width, height: height, time: drawingTime(still: 1.1))
        }
        area.expand(horizontal: true)
        macbeeb_preferences_accessible_hidden(area.widget)
        animate(area) { Int($0 * 30) }
        return area
    }

    static func draw(_ g: Cairo, width: Double, height: Double, time: Double) {
        let dark = isDark
        let line = height * 0.7
        let stations = 4
        let xs = (0..<stations).map { width * (0.14 + 0.24 * Double($0)) }
        let cable: (Double, Double, Double) = dark ? (0.2, 0.78, 0.87) : (0.07, 0.5, 0.6)
        // The cable and the drops.
        g.color(cable.0, cable.1, cable.2, 0.6)
        g.move(width * 0.05, line)
        g.line(width * 0.95, line)
        for x in xs {
            g.move(x, line)
            g.line(x, line - 26)
        }
        g.stroke(width: 2)
        for x in xs {
            let screen = (x: x - 22, y: line - 66, width: 44.0, height: 40.0)
            if dark {
                g.color(1, 1, 1, 0.85)
            } else {
                g.color(0.22, 0.24, 0.26)
            }
            g.roundedRectangle(screen.x, screen.y, screen.width, screen.height, radius: 5)
            g.fill()
            g.color(0, 0, 0)
            g.roundedRectangle(screen.x + 4, screen.y + 4, screen.width - 8, screen.height - 8, radius: 2)
            g.fill()
            g.color(0.2, 0.82, 0.48, 0.85)
            for row in 0..<3 {
                let barWidth = [24.0, 16, 20][(row + Int(x)) % 3]
                g.rectangle(screen.x + 7, screen.y + 8 + Double(row) * 7, barWidth, 3)
            }
            g.fill()
        }
        // Frames from one station to another and back.
        let colours: [UInt32] = [0xF6D32D, 0x33D17A, 0xF66151]
        for packet in 0..<3 {
            let phase = (time * 0.35 + Double(packet) / 3).truncatingRemainder(dividingBy: 1)
            let from = xs[packet % stations], to = xs[(packet + 2) % stations]
            let x = from + (to - from) * (0.5 - 0.5 * cos(phase * .pi * 2))
            g.color(cable.0, cable.1, cable.2, 0.22)
            g.circle(x, line, radius: 10)
            g.fill()
            g.color(hex: colours[packet])
            g.circle(x, line, radius: 5)
            g.fill()
        }
    }
}
