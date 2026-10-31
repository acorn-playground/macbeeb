import BeebCore
import BeebHost
import CGtk
import Foundation

/// The disassembly: the instructions around the PC (or from an address),
/// their labels, breakpoints in the gutter, and the profile's heat. (The
/// Mac's DisassemblyView.)
@MainActor
final class DisassemblyPane {
    let model: DebuggerModel
    private(set) var root: Widget!
    let goTo = Entry(placeholder: "Go to address")
    private let canvas: CodeCanvas
    private let message = Label("", style: "debugger-message")
    private var metrics: TextMetrics
    private var small: TextMetrics

    private enum Row {
        case label(String)
        case line(Int)
    }

    private var lines: [DebugSnapshot.Line] = []
    private var rows: [Row] = []
    private var stopped = false
    /// The stop last scrolled to (so running doesn't pull the view about).
    private var scrolledTo: UInt16?

    init(model: DebuggerModel) {
        self.model = model
        let probe = Label()
        metrics = TextMetrics(CodeFont.code, widget: probe)
        small = TextMetrics(CodeFont.small, widget: probe)
        canvas = CodeCanvas(rowHeight: metrics.lineHeight + 3)
        build()
    }

    private func build() {
        goTo.widthChars(14).style("debugger-code").tooltip("An address, a symbol or an expression (Ctrl+L)")
        goTo.onActivate { [unowned self] in self.go() }
        goTo.onChanged { [unowned self] _ in self.goTo.removeStyle("error") }
        let header = PaneHeader("Disassembly") {
            HSpacer()
            goTo
            Button("PC") { [unowned self] in self.model.view.disassemblyStart = nil }
                .tooltip("Follow the program counter").style("flat")
            IconButton("document-open-symbolic", "Load symbols: ld65 debug info (.dbg) or a label file",
                       label: "Load Symbols") { [unowned self] in self.loadSymbols() }
            Box(.horizontal) {
                IconButton("go-up-symbolic", "Earlier") { [unowned self] in self.shift(-1) }
                IconButton("go-down-symbolic", "Later") { [unowned self] in self.shift(1) }
            }.linked()
        }
        message.wrap().margin(horizontal: 12, vertical: 6).visible(false)

        canvas.drawRow = { [unowned self] painter, palette, row, y, width in
            self.draw(row, painter, palette, y, width)
        }
        canvas.onPress = { [unowned self] row, x, _, presses, button, _ in
            guard row >= 0, button == 1, presses == 1, x < self.gutterEnd, case .line(let index) = self.rows[row] else { return }
            self.model.toggleBreakpoint(at: self.lines[index].address)
        }
        canvas.tooltip = { [unowned self] row, x in
            guard x < self.gutterEnd, case .line(let index) = self.rows[row] else { return nil }
            return self.lines[index].breakpoints.isEmpty ? "Set a breakpoint" : "Remove the breakpoint"
        }
        canvas.cursor = { [unowned self] row, x in
            guard row >= 0, x < self.gutterEnd, case .line = self.rows[row] else { return nil }
            return "pointer"
        }
        canvas.area.accessibleLabel("Disassembly")
        canvas.scroller.style("debugger-view")

        let root = Box(.vertical) {
            header
            Separator()
            canvas.widget
            message
        }
        self.root = root
        root.track { [unowned self] in self.update() }
        root.track { [unowned self] in
            let text = self.model.message
            self.message.text = text ?? ""
            self.message.isVisible = text != nil
        }
        root.keep(self)
    }

    // MARK: State

    private var stoppedPC: UInt16? {
        lines.first { $0.isPC }?.address
    }

    private func update() {
        let snapshot = model.snapshot
        let lines = snapshot?.disassembly ?? []
        let stopped = model.isStopped
        if lines != self.lines || stopped != self.stopped {
            self.lines = lines
            self.stopped = stopped
            rows = []
            for (index, line) in lines.enumerated() {
                rows += line.labels.map { .label($0) }
                rows.append(.line(index))
            }
            canvas.setRows(rows.count)
        }
        // Where it stops is in view (labels above it can push it down), but
        // running doesn't pull the view about.
        let pc = stopped ? stoppedPC : nil
        if pc != scrolledTo {
            scrolledTo = pc
            scrollToPC()
        }
    }

    /// Shows the PC, a third of the way down.
    func scrollToPC() {
        guard let pc = stoppedPC, let row = rows.firstIndex(where: {
            if case .line(let index) = $0 { return lines[index].address == pc }
            return false
        }) else { return }
        canvas.scroll(to: row, anchor: 0.3)
    }

    // MARK: Drawing

    private var gutterStart: Double { 8 }
    private var arrowX: Double { gutterStart + 10 + 8 }
    private var addressX: Double { arrowX + 7 + 8 }
    private var gutterEnd: Double { addressX + 4 * metrics.charWidth + 4 }
    private var bytesX: Double { addressX + 4 * metrics.charWidth + 8 }
    private var textX: Double { bytesX + max(80, 9 * metrics.charWidth) + 8 }

    private func draw(_ row: Int, _ painter: TextPainter, _ palette: Palette, _ y: Double, _ width: Double) {
        let cairo = painter.cairo
        let height = canvas.rowHeight
        let textY = y + (height - metrics.lineHeight) / 2
        switch rows[row] {
        case .label(let name):
            painter.text(name + ":", x: addressX, y: textY, font: CodeFont.code, color: palette.accentText,
                         width: width - addressX - 8)
        case .line(let index):
            let line = lines[index]
            if line.isPC {
                cairo.color(palette.accentBackground, alpha: stopped ? 0.18 : 0.08)
                cairo.rectangle(0, y, width, height)
                cairo.fill()
            }
            // Profile heat: a bar in proportion to the busiest instruction.
            if let heat = line.heat {
                cairo.color(palette.heat, alpha: 0.12 + 0.3 * heat)
                cairo.rectangle(0, y, max(3, width * 0.25 * heat), height)
                cairo.fill()
            }
            let centre = y + height / 2
            cairo.circle(gutterStart + 5, centre, radius: line.breakpoints.isEmpty ? 4.5 : 5)
            if line.breakpoints.isEmpty {
                cairo.color(palette.faint)
                cairo.stroke(width: 1)
            } else {
                cairo.color(palette.breakpoint)
                cairo.fill()
            }
            if line.isPC {
                cairo.color(stopped ? palette.accentText : palette.secondary)
                cairo.move(arrowX, centre - 4)
                cairo.line(arrowX + 7, centre)
                cairo.line(arrowX, centre + 4)
                cairo.fill()
            }
            painter.text(hex(line.address, 4), x: addressX, y: textY, font: CodeFont.code, color: palette.secondary)
            painter.text(line.bytes.map { hex($0) }.joined(separator: " "), x: bytesX, y: textY, font: CodeFont.code,
                         color: palette.secondary)
            var sourceWidth = 0.0
            if let source = line.source {
                sourceWidth = painter.text(source.description, right: width - 8, y: y + (height - small.lineHeight) / 2,
                                           font: CodeFont.small, color: palette.secondary, maxWidth: width * 0.3)
            }
            painter.text(line.text, x: textX, y: textY, font: CodeFont.code, color: palette.foreground,
                         width: width - textX - sourceWidth - 16)
        }
    }

    // MARK: Commands

    private func loadSymbols() {
        Platform.chooseFiles(.any, multiple: false, message: "Choose ld65 debug info (ld65 --dbgfile) or a label file") {
            [model] urls in
            if let url = urls.first { model.loadSymbols(url) }
        }
    }

    private func go() {
        let text = goTo.text
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            if let address = await model.address(text) {
                model.view.disassemblyStart = UInt16(truncatingIfNeeded: address)
            } else {
                goTo.style("error")
                gtk_widget_error_bell(goTo.widget)
            }
        }
    }

    private func shift(_ direction: Int) {
        guard let first = lines.first else { return }
        if direction > 0 {
            model.view.disassemblyStart = lines[min(lines.count - 1, lines.count / 2)].address
        } else {
            model.view.disassemblyStart = first.address &- 48
        }
    }
}
