import BeebCore
import BeebHost
import CGtk
import Foundation

/// Memory: 512 bytes of any of the machine's address spaces, as hex and
/// text, the bytes changed since the last stop picked out; a byte
/// double-clicked is edited. (The Mac's MemoryView.)
@MainActor
final class MemoryPane {
    let model: DebuggerModel
    private(set) var root: Widget!
    private let canvas: CodeCanvas
    private let metrics: TextMetrics
    private let spaces = DropDown([])
    private let address = Entry(placeholder: "Address")
    private var regions: [MemoryRegion] = []
    private var updatingSpaces = false

    private var memory: [UInt8?] = []
    private var previous: [UInt8?] = []
    private var base = 0

    private let editor = Entry(placeholder: "Value")
    private var popover: Popover!
    private var editing: Int?

    init(model: DebuggerModel) {
        self.model = model
        metrics = TextMetrics(CodeFont.small, widget: Label())
        canvas = CodeCanvas(rowHeight: metrics.lineHeight + 3)
        build()
    }

    private func build() {
        spaces.tooltip("The address space shown").accessibleLabel("Space")
        spaces.object.onChange("selected") { [unowned self] in
            guard !self.updatingSpaces else { return }
            let index = self.spaces.selected
            guard self.regions.indices.contains(index) else { return }
            let region = self.regions[index]
            var view = self.model.view
            view.memorySpace = region.space
            // (Into the region, if the address isn't in it.)
            if view.memoryAddress < region.base || view.memoryAddress >= region.base + region.size {
                view.memoryAddress = region.base
            }
            self.model.view = view
        }
        address.widthChars(10).style("debugger-code").tooltip("An address, a symbol or an expression")
        address.onActivate { [unowned self] in self.go() }
        address.onChanged { [unowned self] _ in self.address.removeStyle("error") }
        let header = PaneHeader("Memory") {
            spaces.margin(start: 6)
            HSpacer()
            address
            Box(.horizontal) {
                IconButton("go-up-symbolic", "Back 256 bytes", label: "Earlier") { [unowned self] in self.page(-1) }
                IconButton("go-down-symbolic", "On 256 bytes", label: "Later") { [unowned self] in self.page(1) }
            }.linked()
        }

        canvas.drawRow = { [unowned self] painter, palette, row, y, width in
            self.draw(row, painter, palette, y, width)
        }
        canvas.onPress = { [unowned self] row, x, _, presses, button, _ in
            guard row >= 0, button == 1, presses == 2, let column = self.column(at: x) else { return }
            self.edit(row * 16 + column)
        }
        canvas.tooltip = { [unowned self] row, x in
            guard let column = self.column(at: x) else { return nil }
            let index = row * 16 + column
            guard self.memory.indices.contains(index) else { return nil }
            return "&" + hex(self.base + index, 4) + ": double-click to change it"
        }
        canvas.area.accessibleLabel("Memory")
        canvas.scroller.style("debugger-view")

        editor.widthChars(6).style("debugger-code")
        editor.onActivate { [unowned self] in self.commit() }
        let editorBox = Box(.vertical, spacing: 6) {
            editor
        }.margin(6)
        popover = Popover(editorBox)
        gtk_popover_set_position(cast(popover.widget), GTK_POS_TOP)

        let root = Box(.vertical) {
            header
            Separator()
            canvas.widget
        }
        self.root = root
        root.track { [unowned self] in self.update() }
        root.keep(self)
    }

    // MARK: State

    private func update() {
        let snapshot = model.snapshot
        let regions = snapshot?.regions ?? []
        let space = snapshot?.view.memorySpace ?? model.view.memorySpace
        updatingSpaces = true
        if regions != self.regions {
            self.regions = regions
            spaces.setItems(regions.map(\.name), selected: regions.firstIndex { $0.space == space } ?? 0)
        } else if let index = regions.firstIndex(where: { $0.space == space }) {
            spaces.selected = index
        }
        updatingSpaces = false
        let memory = snapshot?.memory ?? []
        let base = snapshot?.view.memoryAddress ?? 0
        let previous = model.previousMemory
        if memory != self.memory || base != self.base || previous != self.previous {
            self.memory = memory
            self.base = base
            self.previous = previous
            canvas.setRows(memory.count / 16)
        }
    }

    // MARK: Drawing

    private var addressX: Double { 12 }
    private var bytesX: Double { addressX + 5 * metrics.charWidth + 10 }
    private var cellWidth: Double { 3 * metrics.charWidth }

    private func byteX(_ column: Int) -> Double {
        bytesX + Double(column) * cellWidth + (column >= 8 ? metrics.charWidth : 0)
    }

    private var textX: Double { byteX(16) + 8 }

    /// The byte column at x, if there's one there.
    private func column(at x: Double) -> Int? {
        for column in 0..<16 {
            let start = byteX(column) - metrics.charWidth / 2
            if x >= start && x < start + cellWidth { return column }
        }
        return nil
    }

    private func draw(_ row: Int, _ painter: TextPainter, _ palette: Palette, _ y: Double, _ width: Double) {
        let textY = y + (canvas.rowHeight - metrics.lineHeight) / 2
        painter.text(hex(base + row * 16, 4), x: addressX, y: textY, font: CodeFont.small, color: palette.secondary)
        let compare = previous.count == memory.count
        var text = ""
        for column in 0..<16 {
            let index = row * 16 + column
            guard memory.indices.contains(index) else { break }
            let value = memory[index]
            let changed = compare && previous[index] != value
            let x = byteX(column)
            if let value {
                if changed {
                    painter.markup("<b>\(hex(value))</b>", x: x, y: textY, font: CodeFont.small, color: palette.changedText)
                } else {
                    painter.text(hex(value), x: x, y: textY, font: CodeFont.small, color: palette.foreground)
                }
            } else {
                painter.text("--", x: x, y: textY, font: CodeFont.small, color: palette.secondary)
            }
            if let value, value >= 32 && value < 127 {
                text.append(Character(UnicodeScalar(value)))
            } else {
                text.append(".")
            }
        }
        painter.text(text, x: textX, y: textY, font: CodeFont.small, color: palette.secondary)
    }

    // MARK: Editing

    /// Edits the byte at `index` in view (for the self-tests).
    func testEdit(_ index: Int) {
        // (Without a grab, which needs a real click.)
        gtk_popover_set_autohide(cast(popover.widget), 0)
        edit(index)
    }
    var testPopover: Widget { popover }

    private func edit(_ index: Int) {
        guard memory.indices.contains(index) else { return }
        editing = base + index
        editor.text = memory[index].map { hex($0) } ?? ""
        let row = index / 16, column = index % 16
        let x = byteX(column) + metrics.charWidth
        popover.show(on: canvas.area, at: x, y: canvas.localTop(of: row))
        editor.grabFocus()
        editor.selectAll()
    }

    private func commit() {
        if let address = editing, let value = parseHex(editor.text), (0...255).contains(value) {
            model.write(UInt8(value), at: address)
        } else if editing != nil {
            gtk_widget_error_bell(editor.widget)
            return
        }
        editing = nil
        popover.dismiss()
    }

    // MARK: Moving

    private func go() {
        let text = address.text
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            if let address = await model.address(text) {
                model.view.memoryAddress = max(0, address & ~0xF)
            } else {
                self.address.style("error")
                gtk_widget_error_bell(self.address.widget)
            }
        }
    }

    private func page(_ direction: Int) {
        model.view.memoryAddress = max(0, model.view.memoryAddress + direction * 256)
    }
}
