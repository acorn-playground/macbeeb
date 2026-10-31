import BeebCore
import CGtk
import Foundation

// The Hardware window's pictures of memory: the RAM chips to scale, shadow
// RAM's two views, the Aries B32's pool, the sixteen sideways banks, and
// VideoNuLA's palette. Each is made of widgets (so each part has its own
// tooltip and reads to a screen reader), coloured from libadwaita's palette.

/// Blocks side by side, each as wide as its share of `units`.
@MainActor
private func blockGrid(spacing: UInt32) -> Grid {
    let grid = Grid(rowSpacing: 0, columnSpacing: spacing)
    gtk_grid_set_column_homogeneous(cast(grid.widget), 1)
    grid.expand(horizontal: true)
    return grid
}

/// One coloured block: "blue", "green", "purple" or "clear".
@MainActor
private func block(_ colour: String, _ content: Widget, tall: Bool = false) -> Bin {
    let bin = Bin(content).style("hw-block", colour)
    if tall { bin.style("hw-tall") }
    bin.expand(horizontal: true)
    return bin
}

// MARK: The physical memory

/// The physical memory: each chip's share, to scale.
@MainActor
final class MemoryBar {
    struct Block: Equatable {
        var name: String
        var size: Int
        var colour: String
        var help: String
    }

    let widget: Box
    private let grid = blockGrid(spacing: 3)
    private let caption = Label("", style: "caption", "dim-label")
    private var shown: [Block]?

    init() {
        let grid = grid, caption = caption
        caption.wrap()
        widget = Box(.vertical, spacing: 8) {
            grid
            caption
        }
        widget.style("card", "hw-card")
    }

    static func blocks(_ expansions: BBCMicro.Expansions) -> [Block] {
        var blocks = [Block(name: "Main RAM", size: 32, colour: "blue", help: "32K of main RAM at &0000–&7FFF, for programs and the screen")]
        blocks += expansions.sidewaysRAMBanks.map { bank in
            Block(name: "Bank \(bank)", size: 16, colour: "green",
                  help: "16K of sideways RAM, seen at &8000–&BFFF while bank \(bank) is selected")
        }
        if expansions.board == .watford32K {
            blocks.append(Block(name: "Watford board", size: 32, colour: "purple",
                                help: "32K on the Watford board, in place of main RAM at &3000–&7FFF (or all of &0000–&7FFF)"))
        }
        if expansions.board.isAries {
            blocks.append(Block(name: "Aries B32", size: 32, colour: "purple",
                                help: "32K on the B32: banks 13 and 14, less what shadow RAM takes"))
        }
        return blocks
    }

    static func caption(_ expansions: BBCMicro.Expansions) -> String {
        var text = switch expansions.board {
        case .none: "Main RAM is &0000–&7FFF, for programs and the screen."
        case .watford32K: "The board’s RAM stands in for main RAM at the same addresses; the screen is always in main RAM."
        case .ariesB32, .ariesB32B12: "The B32’s 32K is banks 13 and 14, and what shadow RAM takes comes out of them; the screen is always in main RAM."
        }
        if !expansions.sidewaysRAMBanks.isEmpty {
            text += " Sideways RAM appears at &8000–&BFFF, one bank at a time."
        }
        return text
    }

    func update(_ expansions: BBCMicro.Expansions) {
        caption.text = Self.caption(expansions)
        let blocks = Self.blocks(expansions)
        guard blocks != shown else { return }
        shown = blocks
        grid.removeAll()
        var column: Int32 = 0
        for item in blocks {
            // (In 16K units.)
            let span = Int32(item.size / 16)
            let content = Box(.horizontal, spacing: 6) {
                Label(item.name).ellipsize()
                Label("\(item.size)K").style("hw-size")
            }
            content.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER).margin(horizontal: 4)
            grid.attach(block(item.colour, content).tooltip(item.help), column: column, row: 0, width: span)
            column += span
        }
        grid.accessibleLabel(blocks.map(\.help).joined(separator: "; "))
    }
}

// MARK: Shadow RAM

/// Shadow RAM's two views of memory: what programs see, and what the
/// video shows, to scale from &0000 to &8000; the board's state as the BBC
/// runs.
@MainActor
final class ShadowMap {
    let widget: Box
    private let programs = blockGrid(spacing: 2)
    private let screen = blockGrid(spacing: 2)
    private let dot = Bin().style("hw-status-dot")
    private let status = Label("", style: "dim-label")
    private let statusLine: Box
    private var shownStart: Int?

    init() {
        let programs = programs, screen = screen, dot = dot, status = status
        status.wrap().expand(horizontal: true)
        dot.align(vertical: GTK_ALIGN_CENTER)
        let statusLine = Box(.horizontal, spacing: 8) {
            dot
            status
        }
        // (One grid, so the two bars line up.)
        func heading(_ title: String, _ detail: String) -> Widget {
            Box(.vertical, spacing: 1) {
                Label(title, style: "heading")
                Label(detail, style: "caption", "dim-label").wrap().maxWidthChars(20)
            }
            .size(width: 150)
            .align(vertical: GTK_ALIGN_CENTER)
        }
        let rows = Grid(rowSpacing: 12, columnSpacing: 12)
        rows.attach(heading("Programs", "The CPU, with shadow RAM on"), column: 0, row: 0)
        rows.attach(programs, column: 1, row: 0)
        rows.attach(heading("Screen", "The video, always"), column: 0, row: 1)
        rows.attach(screen, column: 1, row: 1)
        self.statusLine = statusLine
        widget = Box(.vertical, spacing: 12) {
            rows
            statusLine
        }
        widget.style("card", "hw-card")
        // The screen's always where it is.
        fill(screen, [("", "&0000", 12, "clear"), ("Main RAM: the screen", "&3000", 20, "blue")])
    }

    /// `shadowStartK`: where the board's RAM starts for programs, in K: 12
    /// (&3000), 16 (&4000), or 32 for none.
    func update(shadowStartK: Int, status text: String, purple: Bool, help: String) {
        status.text = text
        dot.setStyle("purple", purple)
        dot.setStyle("blue", !purple)
        statusLine.tooltip(help)
        widget.accessibleLabel("Programs see main RAM up to &\(String(format: "%04X", min(shadowStartK, 32) * 1024))"
                               + (shadowStartK < 32 ? ", then the board’s RAM" : "") + "; the screen is in main RAM at &3000. " + text)
        guard shadowStartK != shownStart else { return }
        shownStart = shadowStartK
        fill(programs, shadowStartK >= 32
             ? [("Main RAM", "&0000", 32, "blue")]
             : [("Main RAM", "&0000", shadowStartK, "blue"),
                ("Board RAM", String(format: "&%04X", shadowStartK * 1024), 32 - shadowStartK, "purple")])
    }

    /// Segments of (name, start address, size in K, colour), in 4K units.
    private func fill(_ grid: Grid, _ segments: [(String, String, Int, String)]) {
        grid.removeAll()
        var column: Int32 = 0
        for (name, start, size, colour) in segments {
            let span = Int32(size / 4)
            let title = Label(name).ellipsize().centred()
            title.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER).margin(horizontal: 4)
            let address = Label(start, style: "hw-address").align(horizontal: GTK_ALIGN_START, vertical: GTK_ALIGN_START)
            let overlay = Overlay(title) { address }
            grid.attach(block(colour, overlay), column: column, row: 0, width: span)
            column += span
        }
    }
}

/// The Aries B32's 32K, as banks 13 and 14: how much is shadow RAM and how
/// much sideways RAM, and where writes go, as the BBC runs.
@MainActor
final class AriesPool {
    let widget: Box
    private let title = Label("", style: "heading")
    private let pool = blockGrid(spacing: 3)
    private let shadowIcon = Icon("view-reveal-symbolic")
    private let shadowLabel = Label("", style: "caption")
    private let writesLabel = Label("", style: "caption")
    private let states: Box
    private var shownK: Int?

    init() {
        let title = title, pool = pool, shadowIcon = shadowIcon, shadowLabel = shadowLabel, writesLabel = writesLabel
        title.wrap()
        writesLabel.ellipsize()
        let states = Box(.horizontal, spacing: 18) {
            Box(.horizontal, spacing: 6) { shadowIcon; shadowLabel }
            Box(.horizontal, spacing: 6) { Icon("document-edit-symbolic"); writesLabel }
        }
        states.style("dim-label")
        self.states = states
        widget = Box(.vertical, spacing: 10) {
            title
            pool
            states
            Label("*XON, *XON 16 and *XOFF choose the split; it changes at the next MODE or Break.", style: "caption", "dim-label").wrap()
        }
        widget.style("card", "hw-card")
    }

    func update(_ state: BBCMicro.AriesState?) {
        let allocation = state?.shadowAllocation ?? "20K shadow (&3000–&7FFF) + 12K sideways RAM"
        title.text = allocation.prefix(1).capitalized + allocation.dropFirst()
        states.isVisible = state != nil
        if let state {
            shadowIcon.name = state.shadow ? "view-reveal-symbolic" : "view-conceal-symbolic"
            shadowLabel.text = state.shadow ? "Shadow on (&FE3F)" : "Shadow off (&FE3E)"
            writesLabel.text = "Writes: \(state.writeTarget)"
            writesLabel.tooltip("Writes: \(state.writeTarget)")
        }
        let k = state?.shadowK ?? 20
        widget.accessibleLabel(title.text + (state.map { ". \(shadowLabel.text). Writes: \($0.writeTarget)" } ?? ""))
        guard k != shownK else { return }
        shownK = k
        let bank13 = k > 0
            ? ("Shadow", "Bank 13 = &4000–&7FFF", 16, true)
            : ("Sideways RAM", "Bank 13 · &8000–&BFFF", 16, false)
        let pieces = k == 20
            ? [bank13, ("Sideways RAM", "Bank 14 · &8000–&AFFF", 12, false), ("Shadow", "= &3000–&3FFF", 4, true)]
            : [bank13, ("Sideways RAM", "Bank 14 · &8000–&BFFF", 16, false)]
        pool.removeAll()
        var column: Int32 = 0
        for (label, range, size, shadow) in pieces {
            let span = Int32(size / 4)
            let content = Box(.vertical, spacing: 2) {
                Label(label).ellipsize().centred()
                Label(range, style: "hw-range").ellipsize().centred()
            }
            content.align(vertical: GTK_ALIGN_CENTER).margin(horizontal: 4)
            pool.attach(block(shadow ? "purple" : "green", content, tall: true).tooltip("\(label): \(range)"),
                        column: column, row: 0, width: span)
            column += span
        }
    }
}

// MARK: The sideways banks

/// What a bank of the machine the draft would build is.
struct PlannedSlot: Equatable {
    enum Kind { case rom, ram, emptySocket, notFitted }
    var bank: Int
    var kind: Kind
    var title: String
    var detail: String
    var hasImage: Bool
}

/// Banks 0-15 in a row: ROM, RAM, an empty socket or nothing; a dot under
/// the one selected in ROMSEL just now.
@MainActor
final class BankStrip {
    private struct Cell {
        let column: Box
        let cell: Box
        let number: Label
        let kind: Label
        let dot: Bin
    }

    let widget: Box
    private var cells: [Cell] = []

    init() {
        widget = Box(.horizontal, spacing: 4).homogeneous()
        for bank in 0..<16 {
            let number = Label("\(bank)", style: "hw-bank-number").centred()
            let kind = Label("", style: "hw-bank-kind").centred()
            let content = Box(.vertical, spacing: 0) { number; kind }
            content.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER).expand(vertical: true)
            let cell = Box(.vertical) { content }.style("hw-bank")
            let dot = Bin().style("hw-dot")
            dot.align(horizontal: GTK_ALIGN_CENTER)
            let column = Box(.vertical, spacing: 4) { cell; dot }
            widget.append(column)
            cells.append(Cell(column: column, cell: cell, number: number, kind: kind, dot: dot))
        }
    }

    func update(_ slots: [PlannedSlot], selected: Int?) {
        for slot in slots where cells.indices.contains(slot.bank) {
            let cell = cells[slot.bank]
            for kind in ["rom", "ram", "empty", "not-fitted"] {
                cell.cell.setStyle(kind, kind == Self.style(slot.kind))
            }
            cell.kind.text = Self.label(slot.kind)
            cell.dot.setStyle("selected", selected == slot.bank)
            let help = Self.help(slot, selected: selected)
            cell.column.tooltip(help)
            cell.column.accessibleLabel(help)
        }
    }

    private static func style(_ kind: PlannedSlot.Kind) -> String {
        switch kind {
        case .rom: "rom"
        case .ram: "ram"
        case .emptySocket: "empty"
        case .notFitted: "not-fitted"
        }
    }

    private static func label(_ kind: PlannedSlot.Kind) -> String {
        switch kind {
        case .rom: "ROM"
        case .ram: "RAM"
        case .emptySocket: "EMPTY"
        case .notFitted: "—"
        }
    }

    private static func help(_ slot: PlannedSlot, selected: Int?) -> String {
        var text = "Bank \(slot.bank): \(slot.title)"
        if !slot.detail.isEmpty { text += " (\(slot.detail))" }
        if selected == slot.bank { text += ". Selected now" }
        return text
    }
}

// MARK: VideoNuLA

/// VideoNuLA's sixteen colours as the BBC has set them, live.
@MainActor
final class NuLAPalette {
    private struct Swatch {
        let column: Box
        let area: DrawingArea
        let hex: Label
    }

    let widget: Box
    private var swatches: [Swatch] = []
    private var colours = [UInt16](repeating: 0, count: 16)
    private var flashing = [Bool](repeating: false, count: 16)
    private let modeIcon = Icon("preferences-color-symbolic")
    private let mode = Label("", style: "caption")
    private let offset = Label("", style: "caption")
    private let blanking = Label("", style: "caption")
    private let offsetLine: Box
    private let blankingLine: Box

    init() {
        let row = Box(.horizontal, spacing: 4).homogeneous()
        let modeIcon = modeIcon, mode = mode, offset = offset, blanking = blanking
        let offsetLine = Box(.horizontal, spacing: 6) { Icon("format-indent-more-symbolic"); offset }
        let blankingLine = Box(.horizontal, spacing: 6) { Icon("selection-start-symbolic"); blanking }
        self.offsetLine = offsetLine
        self.blankingLine = blankingLine
        let status = Box(.horizontal, spacing: 16) {
            Box(.horizontal, spacing: 6) { modeIcon; mode }
            offsetLine
            blankingLine
        }
        status.style("dim-label")
        widget = Box(.vertical, spacing: 8) {
            row
            status
        }
        widget.margin(12)
        for index in 0..<16 {
            let area = DrawingArea(height: 30) { _, _, _ in }
            area.setDraw { [weak self] cairo, width, height in
                self?.drawSwatch(index, cairo, width, height, area: area)
            }
            area.expand(horizontal: true)
            let hex = Label("000", style: "hw-swatch-hex", "dim-label").centred()
            let column = Box(.vertical, spacing: 3) {
                area
                Label("\(index)", style: "hw-swatch-number").centred()
                hex
            }
            row.append(column)
            swatches.append(Swatch(column: column, area: area, hex: hex))
        }
    }

    private func drawSwatch(_ index: Int, _ cairo: Cairo, _ width: Double, _ height: Double, area: DrawingArea) {
        let c = colours[index]
        cairo.roundedRectangle(0.5, 0.5, width - 1, height - 1, radius: 5)
        cairo.color(Double(c >> 8 & 15) / 15, Double(c >> 4 & 15) / 15, Double(c & 15) / 15)
        cairo.fillPreserve()
        cairo.foreground(of: area, alpha: 0.18)
        cairo.stroke(width: 1)
        guard flashing[index] else { return }
        // A bolt, top right.
        let x = width - 11, y = 3.0
        cairo.move(x + 5, y)
        cairo.line(x + 1, y + 6)
        cairo.line(x + 4, y + 6)
        cairo.line(x + 2.5, y + 11)
        cairo.line(x + 7.5, y + 4.5)
        cairo.line(x + 4.5, y + 4.5)
        cairo.line(x + 6, y)
        cairo.color(1, 1, 1)
        cairo.fillPreserve()
        cairo.color(0, 0, 0, 0.45)
        cairo.stroke(width: 0.6)
    }

    func update(_ nula: MachineController.NuLAView) {
        for index in 0..<16 where index < nula.colours.count {
            let c = nula.colours[index] & 0xFFF
            let flash = nula.flashing[index]
            let swatch = swatches[index]
            if c != colours[index] || flash != flashing[index] {
                colours[index] = c
                flashing[index] = flash
                swatch.area.queueDraw()
            }
            swatch.hex.text = String(format: "%03X", c)
            swatch.column.tooltip(String(format: "Colour %d: RGB444 &%03X (#%02X%02X%02X)%@", index, c, Int(c >> 8 & 15) * 17,
                                         Int(c >> 4 & 15) * 17, Int(c & 15) * 17, flash ? ", flashing" : ""))
        }
        mode.text = nula.disabled ? "Disabled by the BBC until power off" : nula.direct ? "Direct palette" : "Through the ULA’s palette"
        modeIcon.name = nula.disabled ? "action-unavailable-symbolic" : "preferences-color-symbolic"
        offset.text = "Offset \(nula.offset)"
        offsetLine.isVisible = nula.offset > 0
        blanking.text = "Left blanking \(nula.blanking)"
        blankingLine.isVisible = nula.blanking > 0
        widget.accessibleLabel("VideoNuLA colours: " + (0..<16).map { String(format: "%d %03X", $0, colours[$0]) }.joined(separator: ", "))
    }
}
