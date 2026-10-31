import CGtk
import Foundation

/// A cell of an `ItemTable`: a widget showing one row, made once and shown
/// for whichever row it's given (GtkColumnView recycles them).
@MainActor
class TableCell {
    let widget: Widget
    /// The row it shows now, by index into the caller's array.
    fileprivate(set) var row = 0

    init(_ widget: Widget) {
        self.widget = widget
    }

    /// Shows `row`.
    func bind() {}
}

/// A table whose cells are widgets (names to edit in place, pickers),
/// with several rows selectable, a context menu and the Delete key: the
/// Mac's Table with a contextMenu. Rows are by index into the caller's
/// array.
@MainActor
final class ItemTable: Widget {
    private let store: OpaquePointer
    private let selection: OpaquePointer
    private var cells: [UnsafeMutableRawPointer: TableCell] = [:]
    private(set) var count = 0
    /// A secondary click: the rows it's for (selected first), and where, in
    /// the table.
    var onContextMenu: (@MainActor (Set<Int>, Double, Double) -> Void)?

    init() {
        let store = gtk_string_list_new(nil)!
        let selection = gtk_multi_selection_new(cast(store))!
        self.store = store
        self.selection = selection
        super.init(gtk_column_view_new(cast(selection))!)
        gtk_column_view_set_show_column_separators(cast(widget), 0)
        gtk_column_view_set_reorderable(cast(widget), 0)
        style("data-table")
    }

    private static func index(_ item: UnsafeMutableRawPointer?) -> Int {
        guard let item, let object = macbeeb_string_object(item) else { return 0 }
        return Int(String(cString: gtk_string_object_get_string(object))) ?? 0
    }

    /// Adds a column of cells `make` makes.
    func column(_ title: String, expand: Bool = false, width: Int32 = -1, _ make: @escaping @MainActor () -> TableCell) {
        let factory = gtk_signal_list_item_factory_new()!
        typealias Item = @MainActor (OpaquePointer) -> Void
        let setup: Item = { item in
            let cell = make()
            gtk_list_item_set_child(item, cell.widget.widget)
            self.cells[UnsafeMutableRawPointer(item)] = cell
            cell.widget.onContextClick { [weak cell] x, y in
                guard let cell else { return }
                self.contextClick(cell, x, y)
            }
        }
        let bind: Item = { item in
            guard let cell = self.cells[UnsafeMutableRawPointer(item)] else { return }
            cell.row = Self.index(gtk_list_item_get_item(item))
            cell.bind()
        }
        let teardown: Item = { item in
            self.cells[UnsafeMutableRawPointer(item)] = nil
        }
        for (signal, body) in [("setup", setup), ("bind", bind), ("teardown", teardown)] {
            macbeeb_signal_connect(gpointer(factory), signal, unsafeBitCast(
                { (_: gpointer?, item: gpointer?, data: gpointer?) in
                    nonisolated(unsafe) let item = item, data = data
                    MainActor.assumeIsolated {
                        guard let item else { return }
                        Boxed<Item>.from(data)(OpaquePointer(item))
                    }
                } as @convention(c) (gpointer?, gpointer?, gpointer?) -> Void, to: GCallback.self),
                Boxed<Item>(body).retained, { data, _ in AnyBox.release(data) }, 0)
        }
        let column = gtk_column_view_column_new(title, factory)!
        gtk_column_view_column_set_expand(column, expand ? 1 : 0)
        gtk_column_view_column_set_resizable(column, 1)
        if width > 0 { gtk_column_view_column_set_fixed_width(column, width) }
        gtk_column_view_append_column(cast(widget), column)
        g_object_unref(gpointer(column))
    }

    /// The cell showing `row` in a column made by `type`, if it's shown.
    func cell<T: TableCell>(_ type: T.Type, row: Int) -> T? {
        cells.values.lazy.compactMap { $0 as? T }.first { $0.row == row }
    }

    /// Shows `count` rows (the caller's array changed). The selection's
    /// cleared: the caller selects again by what the rows are.
    func reload(count: Int) {
        self.count = count
        let items = (0..<count).map(String.init)
        withCStringArray(items) { strings in
            gtk_string_list_splice(cast(store), 0, g_list_model_get_n_items(cast(store)), strings)
        }
    }

    var selectedRows: Set<Int> {
        var rows = Set<Int>()
        for position in 0..<g_list_model_get_n_items(cast(selection)) where gtk_selection_model_is_selected(cast(selection), position) != 0 {
            rows.insert(Int(position))
        }
        return rows
    }

    func select(_ rows: Set<Int>) {
        gtk_selection_model_unselect_all(cast(selection))
        for row in rows where row < count {
            gtk_selection_model_select_item(cast(selection), guint(row), 0)
        }
    }

    /// The selection changed.
    @discardableResult
    func onSelectionChanged(_ body: @escaping @MainActor () -> Void) -> Self {
        typealias Changed = @MainActor () -> Void
        // (`selection-changed` passes a position and a count before the data.)
        macbeeb_signal_connect(gpointer(selection), "selection-changed", unsafeBitCast(
            { (_: gpointer?, _: guint, _: guint, data: gpointer?) in
                nonisolated(unsafe) let data = data
                MainActor.assumeIsolated { Boxed<Changed>.from(data)() }
            } as @convention(c) (gpointer?, guint, guint, gpointer?) -> Void, to: GCallback.self),
            Boxed<Changed>(body).retained, { data, _ in AnyBox.release(data) }, 0)
        return self
    }

    /// A row activated (double-clicked, or Return): its index.
    @discardableResult
    func onActivate(_ body: @escaping @MainActor (Int) -> Void) -> Self {
        object.onInt("activate") { position in body(Int(position)) }
        return self
    }

    /// Keys pressed in the table (Delete, F2…): true takes it.
    @discardableResult
    func onKey(_ body: @escaping @MainActor (UInt32) -> Bool) -> Self {
        add(KeyController().onPressed { keyval, _, _ in body(keyval) })
    }

    private func contextClick(_ cell: TableCell, _ x: Double, _ y: Double) {
        if !selectedRows.contains(cell.row) { select([cell.row]) }
        var point = graphene_point_t(x: Float(x), y: Float(y))
        var out = graphene_point_t()
        _ = gtk_widget_compute_point(cell.widget.widget, widget, &point, &out)
        onContextMenu?(selectedRows, Double(out.x), Double(out.y))
    }
}

/// A table cell that's a name, renamed in place (F2, or its menu's Rename).
@MainActor
final class NameCell: TableCell {
    private let label: UnsafeMutablePointer<GtkWidget>
    private let name: (Int) -> String
    private var showing = ""

    /// `name` gives a row's name; `rename` renames it.
    init(name: @escaping (Int) -> String, rename: @escaping (Int, String) -> Void) {
        let label = gtk_editable_label_new("")!
        self.label = label
        self.name = name
        super.init(Widget(label))
        widget.expand(horizontal: true)
        // Clicks select the row; editing starts from the keyboard or a menu.
        widget.canTarget(false)
        let editable = label
        widget.object.onChange("editing") { [weak self] in
            guard let self else { return }
            let editing = gtk_editable_label_get_editing(cast(editable)) != 0
            self.widget.canTarget(editing)
            guard !editing else { return }
            let text = String(cString: gtk_editable_get_text(cast(editable)))
            if text != self.showing { rename(self.row, text) }
        }
    }

    override func bind() {
        showing = name(row)
        gtk_editable_set_text(cast(label), showing)
    }

    func startEditing() {
        widget.canTarget(true)
        gtk_editable_label_start_editing(cast(label))
    }
}

/// A table cell of text, perhaps quiet ("dim-label"), with a tooltip.
@MainActor
final class TextCell: TableCell {
    private let label: Label
    private let text: (Int) -> (text: String, quiet: Bool, tooltip: String?)

    init(numeric: Bool = false, _ text: @escaping (Int) -> (text: String, quiet: Bool, tooltip: String?)) {
        label = Label("")
        label.ellipsize()
        if numeric { label.style("numeric") }
        self.text = text
        super.init(label)
        label.expand(horizontal: true)
    }

    override func bind() {
        let shown = text(row)
        label.text = shown.text
        label.setStyle("dim-label", shown.quiet)
        label.tooltip(shown.tooltip)
    }
}
