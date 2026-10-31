import CGtk
import Foundation

/// A table of rows and columns (GtkColumnView): the Mac's Table. Rows are
/// by index into the caller's own array; each column says what a row
/// shows, and how rows sort by it (clicking its header sorts).
///
///     let table = Table(selection: .multiple)
///     table.column("Name", expand: true) { row in files[row].name }
///         .sorted { files[$0].name.localizedStandardCompare(files[$1].name) == .orderedAscending }
///     table.column("Length", monospace: true, alignRight: true) { row in "\(files[row].length)" }
///     table.reload(count: files.count)
@MainActor
final class Table: Widget {
    enum Selection {
        case none, single, multiple
    }

    /// The rows, as indices (GtkStringObjects of their numbers).
    private let store: OpaquePointer
    private let sortModel: OpaquePointer
    private let selectionModel: OpaquePointer
    private let selectionKind: Selection
    private var columns: [Column] = []
    private var count = 0

    final class Column {
        let column: OpaquePointer
        let text: @MainActor (Int) -> String
        let style: [String]
        let alignRight: Bool
        fileprivate var compare: (@MainActor (Int, Int) -> Bool)?

        fileprivate init(column: OpaquePointer, text: @escaping @MainActor (Int) -> String, style: [String], alignRight: Bool) {
            self.column = column
            self.text = text
            self.style = style
            self.alignRight = alignRight
        }

        /// How rows sort by this column: `before(a, b)` when a comes first
        /// ascending.
        @discardableResult
        func sorted(_ before: @escaping @MainActor (Int, Int) -> Bool) -> Column {
            compare = before
            typealias Compare = @MainActor (Int, Int) -> Bool
            let sorter = gtk_custom_sorter_new({ a, b, data in
                nonisolated(unsafe) let a = a, b = b, data = data
                return MainActor.assumeIsolated {
                    let before = Boxed<Compare>.from(data)
                    let x = Table.index(a), y = Table.index(b)
                    return before(x, y) ? -1 : before(y, x) ? 1 : 0
                }
            }, Boxed<Compare>(before).retained, { AnyBox.release($0) })
            gtk_column_view_column_set_sorter(column, cast(sorter!))
            g_object_unref(gpointer(sorter))
            return self
        }
    }

    init(selection: Selection = .single) {
        store = cast(gtk_string_list_new(nil)!)
        selectionKind = selection
        let view = gtk_column_view_new(nil)!
        sortModel = cast(gtk_sort_list_model_new(cast(store), nil)!)
        g_object_ref(gpointer(store))
        switch selection {
        case .none: selectionModel = cast(gtk_no_selection_new(cast(sortModel))!)
        case .single:
            let single = gtk_single_selection_new(cast(sortModel))!
            gtk_single_selection_set_autoselect(single, 0)
            gtk_single_selection_set_can_unselect(single, 1)
            selectionModel = cast(single)
        case .multiple: selectionModel = cast(gtk_multi_selection_new(cast(sortModel))!)
        }
        g_object_ref(gpointer(sortModel))
        super.init(view)
        gtk_column_view_set_model(cast(widget), cast(selectionModel))
        // Sorting follows the column headers.
        gtk_sort_list_model_set_sorter(cast(sortModel), gtk_column_view_get_sorter(cast(widget)))
        gtk_column_view_set_show_column_separators(cast(widget), 0)
        gtk_column_view_set_reorderable(cast(widget), 0)
        style("data-table")
    }

    fileprivate static func index(_ item: UnsafeRawPointer?) -> Int {
        guard let item, let object = macbeeb_string_object(UnsafeMutableRawPointer(mutating: item)) else { return 0 }
        return Int(String(cString: gtk_string_object_get_string(object))) ?? 0
    }

    /// Adds a column showing `text` of each row.
    @discardableResult
    func column(_ title: String, expand: Bool = false, width: Int32 = -1, monospace: Bool = false,
                alignRight: Bool = false, _ text: @escaping @MainActor (Int) -> String) -> Column {
        let factory = gtk_signal_list_item_factory_new()!
        let column = gtk_column_view_column_new(title, factory)!
        let entry = Column(column: column, text: text, style: monospace ? ["monospace"] : [], alignRight: alignRight)
        typealias Setup = @MainActor (OpaquePointer) -> Void
        let setup: Setup = { item in
            let label = gtk_label_new(nil)!
            gtk_label_set_xalign(cast(label), alignRight ? 1 : 0)
            gtk_label_set_ellipsize(cast(label), PANGO_ELLIPSIZE_END)
            if monospace { gtk_widget_add_css_class(label, "monospace") }
            gtk_list_item_set_child(item, label)
        }
        let bind: Setup = { item in
            guard let label = gtk_list_item_get_child(item) else { return }
            gtk_label_set_text(cast(label), text(Table.index(gtk_list_item_get_item(item))))
        }
        for (signal, body) in [("setup", setup), ("bind", bind)] {
            macbeeb_signal_connect(gpointer(factory), signal, unsafeBitCast(
                { (_: gpointer?, item: gpointer?, data: gpointer?) in
                    nonisolated(unsafe) let item = item, data = data
                    MainActor.assumeIsolated {
                        guard let item else { return }
                        Boxed<Setup>.from(data)(OpaquePointer(item))
                    }
                } as @convention(c) (gpointer?, gpointer?, gpointer?) -> Void, to: GCallback.self),
                Boxed<Setup>(body).retained, { data, _ in AnyBox.release(data) }, 0)
        }
        gtk_column_view_column_set_expand(column, expand ? 1 : 0)
        gtk_column_view_column_set_resizable(column, 1)
        if width > 0 { gtk_column_view_column_set_fixed_width(column, width) }
        gtk_column_view_append_column(cast(widget), column)
        columns.append(entry)
        return entry
    }

    /// Shows `count` rows (the caller's array changed), keeping the
    /// selection by index where it can.
    func reload(count: Int) {
        let selected = selectedRows
        self.count = count
        let items = (0..<count).map(String.init)
        withCStringArray(items) { strings in
            gtk_string_list_splice(cast(store), 0, guint(gtk_string_list_get_n_items_shim(store)), strings)
        }
        select(selected.filter { $0 < count })
    }

    /// Redraws the rows as they are (same count).
    func refresh() {
        reload(count: count)
    }

    /// Sorts by a column (its index), ascending or not.
    func sort(by column: Int, ascending: Bool = true) {
        guard columns.indices.contains(column) else { return }
        gtk_column_view_sort_by_column(cast(widget), columns[column].column,
                                       ascending ? GTK_SORT_ASCENDING : GTK_SORT_DESCENDING)
    }

    /// The rows selected, by index into the caller's array.
    var selectedRows: Set<Int> {
        let n = g_list_model_get_n_items(cast(selectionModel))
        var rows = Set<Int>()
        for position in 0..<n where gtk_selection_model_is_selected(cast(selectionModel), position) != 0 {
            if let item = g_list_model_get_item(cast(selectionModel), position) {
                rows.insert(Self.index(item))
                g_object_unref(item)
            }
        }
        return rows
    }

    func select(_ rows: Set<Int>) {
        let n = g_list_model_get_n_items(cast(selectionModel))
        gtk_selection_model_unselect_all(cast(selectionModel))
        for position in 0..<n {
            guard let item = g_list_model_get_item(cast(selectionModel), position) else { continue }
            if rows.contains(Self.index(item)) {
                gtk_selection_model_select_item(cast(selectionModel), position, 0)
            }
            g_object_unref(item)
        }
    }

    /// The selection changed.
    @discardableResult
    func onSelectionChanged(_ body: @escaping @MainActor (Set<Int>) -> Void) -> Self {
        // (`selection-changed` passes a position and a count before the
        // data: not GObjectRef.on's shape.)
        typealias Changed = @MainActor () -> Void
        let changed: Changed = { [unowned self] in body(self.selectedRows) }
        macbeeb_signal_connect(gpointer(selectionModel), "selection-changed", unsafeBitCast(
            { (_: gpointer?, _: guint, _: guint, data: gpointer?) in
                nonisolated(unsafe) let data = data
                MainActor.assumeIsolated { Boxed<Changed>.from(data)() }
            } as @convention(c) (gpointer?, guint, guint, gpointer?) -> Void, to: GCallback.self),
            Boxed<Changed>(changed).retained, { data, _ in AnyBox.release(data) }, 0)
        return self
    }

    /// A row activated (double-clicked, or Return): its index.
    @discardableResult
    func onActivate(_ body: @escaping @MainActor (Int) -> Void) -> Self {
        let model = selectionModel
        object.onInt("activate") { position in
            guard let item = g_list_model_get_item(cast(model), guint(position)) else { return }
            body(Table.index(item))
            g_object_unref(item)
        }
        return self
    }

    @discardableResult
    func showsHeaders(_ on: Bool) -> Self {
        // (Headers are always shown by GtkColumnView; a style can hide them.)
        if !on { style("no-headers") }
        return self
    }
}

private func gtk_string_list_get_n_items_shim(_ list: OpaquePointer) -> guint {
    g_list_model_get_n_items(cast(list))
}
