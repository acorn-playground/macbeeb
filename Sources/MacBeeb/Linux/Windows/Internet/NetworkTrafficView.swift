import BeebCore
import BeebNetwork
import CGtk
import Foundation

/// The studio's Traffic view: every frame on the line, as the four-way
/// handshake reads them, with what's in them. (The Mac's
/// NetworkTrafficView.)
@MainActor
enum NetworkTrafficView {
    static let refresh = 0.25
    /// The most frames listed (only the latest are kept).
    static let limit = 4096

    static func make(session: NetworkSession) -> Widget {
        InternetStyles.install()
        let view = TrafficView(session: session)
        view.root.keep(view)
        return view.root
    }
}

/// A traffic capture as saved: MacBeeb's own JSON, documented in the
/// Network Studio guide (the Mac's TrafficExport).
private struct TrafficCapture: Codable {
    var format = "MacBeeb Econet trace 1"
    var network: String
    /// The frames' times are in these.
    var cyclesPerSecond: Int
    var frames: [EconetFrame]
}

@MainActor
private final class TrafficView {
    let session: NetworkSession
    let root = Box(.vertical)
    private var frames: [EconetFrame] = []
    private var station: Int?
    private var problemsOnly = false
    private var search = ""
    /// The Distributed Mandelbrot demo's messages, by transaction.
    private var reader = MandelbrotTraffic()
    private var readings: [Int: MandelbrotReading] = [:]
    private var timer: MainTimer?

    private let list = FrameList()
    private let detail = Stack()
    private let detailBox = Box(.vertical, spacing: 12)
    private let detailScroller: ScrolledWindow
    private let empty = StatusPage(icon: "network-transmit-receive-symbolic", title: "No Frame Selected")

    private let recordButton = ToggleButton(isOn: true)
    private let recordContent = adw_button_content_new()!
    private let exportButton = Button("_Export…", icon: "document-save-symbolic")
    private let stationPicker = DropDown(["All stations"])
    private var stationChoices: [Int?] = [nil]
    /// The stations' numbers and names, as last shown.
    private var stationNames: [String]?
    private let searchEntry: SearchEntry
    private let totals = Label("", style: "dim-label", "numeric")

    init(session: NetworkSession) {
        self.session = session
        detailScroller = ScrolledWindow(detailBox, horizontal: GTK_POLICY_NEVER)
        searchEntry = SearchEntry(placeholder: "Search bytes or text") { _ in }
        root.append(header())
        root.append(Separator())
        root.append(content())
        observe()
    }

    // MARK: Header

    private func header() -> Widget {
        let network = session.runtime.network
        recordButton.isOn = network.isTracing
        gtk_button_set_child(cast(recordButton.widget), recordContent)
        updateRecordButton()
        recordButton.tooltip("Record frames as they cross the line")
        recordButton.object.on("toggled") { [weak self] in
            guard let self else { return }
            network.setTracing(self.recordButton.isOn)
            self.updateRecordButton()
        }
        let clear = Button("_Clear", icon: "user-trash-symbolic") { [weak self] in self?.clear() }
            .tooltip("Forget the frames listed")
        exportButton.onClicked { [weak self] in self?.export() }
            .tooltip("Save the frames as JSON (MacBeeb's own format, not PCAP)")
            .enabled(false)
        for button in [recordButton, clear, exportButton] as [Widget] {
            button.style("flat")
            // (Mnemonics in the label: Alt+C, Alt+E.)
            if let content = gtk_button_get_child(cast(button.widget)), button !== recordButton {
                adw_button_content_set_use_underline(OpaquePointer(content), 1)
            }
        }

        stationPicker.tooltip("Only frames to or from a station")
        stationPicker.object.onChange("selected") { [weak self] in
            guard let self else { return }
            let index = self.stationPicker.selected
            let station = self.stationChoices.indices.contains(index) ? self.stationChoices[index] : nil
            guard station != self.station else { return }
            self.station = station
            self.refilter()
        }
        let problems = CheckButton("_Problems only") { [weak self] on in
            self?.problemsOnly = on
            self?.refilter()
        }
        problems.tooltip("Only frames that collided or were abandoned")
        searchEntry.object.on("search-changed") { [weak self] in
            guard let self else { return }
            self.search = self.searchEntry.text
            self.refilter()
        }
        searchEntry.object.on("stop-search") { [weak self] in self?.searchEntry.text = "" }
        searchEntry.size(width: 180).accessibleLabel("Search bytes or text")
        totals.ellipsize().tooltip("Counted on the line since the network opened").xalign(1).expand(horizontal: true)
        totals.size(width: 60)

        let bar = Box(.horizontal, spacing: 6) {
            recordButton
            clear
            exportButton
            Separator(GTK_ORIENTATION_VERTICAL).margin(horizontal: 6, vertical: 4)
            stationPicker
            problems
            searchEntry
            totals.margin(start: 6)
        }
        bar.style("toolbar").margin(horizontal: 6)
        // Control-F finds (and Escape, in the search, clears it).
        let keys = KeyController()
        keys.onPressed { [weak self] keyval, _, modifiers in
            guard let self else { return false }
            if keyval == UInt32(GDK_KEY_f) && modifiers.rawValue & GDK_CONTROL_MASK.rawValue != 0 {
                self.searchEntry.grabFocus()
                return true
            }
            return false
        }
        root.add(keys)
        return bar
    }

    private func updateRecordButton() {
        let on = recordButton.isOn
        adw_button_content_set_label(OpaquePointer(recordContent), on ? "Recording" : "Paused")
        adw_button_content_set_icon_name(OpaquePointer(recordContent), on ? "media-record-symbolic" : "media-playback-pause-symbolic")
    }

    // MARK: The frames and the one chosen

    private func content() -> Widget {
        list.column("Time", width: 84, setup: { Self.cellLabel(numeric: true) }) { [weak self] cell, id in
            guard let frame = self?.frame(id) else { return }
            gtk_label_set_text(cast(cell), String(format: "%.3f s", Double(frame.start) / 2_000_000))
        }
        list.column("From", width: 130, setup: { Self.cellLabel() }) { [weak self] cell, id in
            guard let self, let frame = self.frame(id) else { return }
            gtk_label_set_text(cast(cell), self.name(frame.transmitter))
        }
        list.column("To", width: 130, setup: { Self.cellLabel() }) { [weak self] cell, id in
            guard let self, let frame = self.frame(id) else { return }
            gtk_label_set_text(cast(cell), frame.destinationStation.map(self.name) ?? "–")
        }
        list.column("Frame", expand: true, setup: {
            let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
            let icon = gtk_image_new()!
            gtk_box_append(cast(box), icon)
            gtk_box_append(cast(box), Self.cellLabel())
            return box
        }) { [weak self] cell, id in
            guard let self, let frame = self.frame(id), let icon = gtk_widget_get_first_child(cell),
                  let label = gtk_widget_get_next_sibling(icon) else { return }
            gtk_image_set_from_icon_name(cast(icon), Self.icon(frame))
            macbeeb_set_accessible_label(icon, Self.explanation(frame.status))
            gtk_label_set_text(cast(label), self.summary(frame))
            if frame.status == .valid {
                gtk_widget_remove_css_class(cell, "warning")
            } else {
                gtk_widget_add_css_class(cell, "warning")
            }
        }
        list.column("#", width: 56, setup: { Self.cellLabel(numeric: true) }) { [weak self] cell, id in
            guard let frame = self?.frame(id) else { return }
            gtk_label_set_text(cast(cell), frame.transaction.map(String.init) ?? "")
        }
        list.onSelect = { [weak self] id in self?.chose(id) }
        list.view.accessibleLabel("Frames")

        let table = ScrolledWindow(list.view, horizontal: GTK_POLICY_AUTOMATIC)
        table.size(width: 420).expand()
        empty.compact()
        detail.add(empty, name: "empty")
        detail.add(detailScroller, name: "frame")
        detail.visible = "empty"
        detailBox.margin(14)
        detail.size(width: 300)
        gtk_scrolled_window_set_min_content_width(cast(detailScroller.widget), 300)
        let paned = Paned(.horizontal, start: table, end: detail).resizes(start: true, end: false)
        paned.expand()
        updateEmpty()
        return paned
    }

    private static func cellLabel(numeric: Bool = false) -> WidgetPointer {
        let label = gtk_label_new(nil)!
        gtk_label_set_xalign(cast(label), 0)
        gtk_label_set_ellipsize(cast(label), PANGO_ELLIPSIZE_END)
        if numeric { gtk_widget_add_css_class(label, "numeric") }
        return label
    }

    private func observe() {
        let session = session
        root.track { [weak self] in
            // The stations to choose from, as the network changes.
            guard let self else { return }
            let names = session.project.nodes.compactMap { node in node.stationNumber.map { "\($0) \(node.name)" } }
            guard names != self.stationNames else { return }
            self.stationNames = names
            let stations = session.project.stations.compactMap { node in node.stationNumber.map { (node.name, $0) } }
            let choices: [Int?] = [nil] + stations.map { $0.1 }
            let labels = ["All stations"] + stations.map { "\($0.0) (\($0.1))" }
            self.stationChoices = choices
            self.stationPicker.setItems(labels, selected: choices.firstIndex(of: self.station) ?? 0)
            // Names in the list follow.
            self.list.refresh()
        }
        root.track { [weak self] in
            let traffic = session.status.traffic
            let frames = traffic.values.reduce(0) { $0 + $1.frames }
            let collisions = traffic.values.reduce(0) { $0 + $1.collisions }
            self?.totals.text = "\(frames) frames sent · \(collisions) byte-times collided"
        }
        root.onMap { [weak self] in self?.start() }
        root.onUnmap { [weak self] in self?.stop() }
        root.onDestroy { [weak self] in self?.stop() }
    }

    private func start() {
        guard timer == nil else { return }
        recordButton.isOn = session.runtime.network.isTracing
        poll()
        timer = MainTimer.repeating(every: NetworkTrafficView.refresh) { [weak self] in self?.poll() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let newer = session.runtime.network.frames(after: frames.last?.id)
        guard !newer.isEmpty else { return }
        let wasEmpty = frames.isEmpty
        for frame in newer {
            if let reading = reader.read(frame), let transaction = frame.transaction { readings[transaction] = reading }
        }
        frames.append(contentsOf: newer)
        if frames.count > NetworkTrafficView.limit {
            frames.removeFirst(frames.count - NetworkTrafficView.limit)
            let first = frames.first?.transaction ?? 0
            readings = readings.filter { $0.key >= first }
            list.removeOlder(than: frames.first?.id ?? 0)
        }
        let oldest = frames.first?.id ?? 0
        list.prepend(newer.reversed().filter { $0.id >= oldest && passes($0) }.map(\.id))
        exportButton.isEnabled = true
        if wasEmpty { updateEmpty() }
    }

    private func clear() {
        session.runtime.network.clearTrace()
        frames = []
        reader = MandelbrotTraffic()
        readings = [:]
        list.replace([])
        exportButton.isEnabled = false
        chose(nil)
        updateEmpty()
    }

    /// The frames listed: newest first.
    private func refilter() {
        list.replace(frames.reversed().filter(passes).map(\.id))
    }

    private func passes(_ frame: EconetFrame) -> Bool {
        if let station, frame.transmitter != UInt8(clamping: station) && frame.destinationStation != UInt8(clamping: station) {
            return false
        }
        if problemsOnly && frame.status == .valid { return false }
        if !search.isEmpty {
            let text = search.lowercased()
            let bytes = String(decoding: frame.bytes.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, as: UTF8.self).lowercased()
            let hex = frame.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            if !summary(frame).lowercased().contains(text) && !bytes.contains(text) && !hex.contains(text) { return false }
        }
        return true
    }

    /// The frame with `id` (frames are in id order).
    private func frame(_ id: Int) -> EconetFrame? {
        var low = 0, high = frames.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let found = frames[middle].id
            if found == id { return frames[middle] }
            if found < id { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    private func chose(_ id: Int?) {
        guard let id, let frame = frame(id) else {
            detail.visible = "empty"
            return
        }
        // Show who's involved on the canvas too.
        let stations = [frame.transmitter, frame.destinationStation].compactMap { $0 }
        session.selection = Set(session.project.nodes.filter { node in
            node.stationNumber.map { stations.contains(UInt8(clamping: $0)) } ?? false
        }.map(\.id))
        showDetail(frame)
        detail.visible = "frame"
        detailScroller.scrollToTop()
    }

    private func updateEmpty() {
        empty.detail = frames.isEmpty ? "Nothing's crossed the line yet. Try *NET then *CAT on a machine."
            : "Choose a frame to see what's in it."
    }

    // MARK: Reading frames

    /// The demo's message in a data frame, if it's one.
    private func reading(_ frame: EconetFrame) -> MandelbrotReading? {
        guard frame.kind == .data, let transaction = frame.transaction else { return nil }
        return readings[transaction]
    }

    /// The frame, and what's in it where that's known.
    private func summary(_ frame: EconetFrame) -> String {
        reading(frame).map { frame.summary + " · " + $0.summary } ?? frame.summary
    }

    /// What a frame's port is for: the demo's name, if its data was the demo's.
    private func portName(_ frame: EconetFrame) -> String? {
        guard let port = frame.port else { return nil }
        if let transaction = frame.transaction, readings[transaction] != nil, let name = MandelbrotProtocol.portName(port) {
            return name
        }
        return EconetFrame.portName(port)
    }

    private func name(_ station: UInt8) -> String {
        if station == 255 { return "Everyone" }
        return session.project.nodes.first { $0.stationNumber == Int(station) }?.name ?? "Station \(station)"
    }

    private static func icon(_ frame: EconetFrame) -> String {
        switch frame.status {
        case .collided: return "dialog-warning-symbolic"
        case .aborted: return "process-stop-symbolic"
        case .valid:
            switch frame.kind {
            case .scout: return "go-next-symbolic"
            case .acknowledgement: return "object-select-symbolic"
            case .data: return "text-x-generic-symbolic"
            case .broadcast: return "network-wireless-symbolic"
            case .unknown: return "dialog-question-symbolic"
            }
        }
    }

    private static func explanation(_ status: EconetFrame.Status) -> String {
        switch status {
        case .valid: "Complete: closed with its check bytes"
        case .collided: "Spoiled: another station was transmitting at the same time"
        case .aborted: "Abandoned part way: the transmitter stopped or ran dry"
        }
    }

    private static func kindText(_ kind: EconetFrame.Kind) -> String {
        switch kind {
        case .scout: "the scout, asking to send"
        case .acknowledgement: "an acknowledgement"
        case .data: "the data"
        case .broadcast: "a broadcast"
        case .unknown: "not recognised"
        }
    }

    // MARK: Detail

    private func showDetail(_ frame: EconetFrame) {
        let facts = Grid(rowSpacing: 4, columnSpacing: 10)
        var row: Int32 = 0
        func fact(_ label: String, _ value: String) {
            facts.attach(Label(label, style: "dim-label").align(vertical: GTK_ALIGN_START), column: 0, row: row)
            facts.attach(Label(value).wrap().selectable().expand(horizontal: true), column: 1, row: row)
            row += 1
        }
        fact("From", name(frame.transmitter) + " (\(frame.transmitter))")
        if let to = frame.destinationStation { fact("To", name(to) + " (\(to)), network \(frame.destinationNetwork ?? 0)") }
        fact("Status", Self.explanation(frame.status))
        fact("Length", "\(frame.bytes.count) bytes, \(String(format: "%.2f ms", Double(frame.end - frame.start) / 2000)) on the line")
        if let transaction = frame.transaction { fact("Transaction", "#\(transaction): " + Self.kindText(frame.kind)) }
        if let name = portName(frame) { fact("Port", name) }

        let dump = Label(Self.dump(frame.bytes), style: "monospace", "internet-dump").selectable()
        dump.accessibleLabel("The frame's bytes")
        let dumpScroller = ScrolledWindow(dump, horizontal: GTK_POLICY_AUTOMATIC, vertical: GTK_POLICY_NEVER)
        dumpScroller.propagateNaturalHeight()

        detailBox.set {
            Label(frame.summary, style: "heading").wrap().selectable()
            facts
            if let reading = reading(frame) {
                mandelbrot(reading)
            }
            dumpScroller
            Label("Bytes 0-3 are who it's to and from (station, network); a scout's byte 4 is the control byte and byte 5 the port. The check bytes aren't shown.",
                  style: "caption", "dim-label").wrap()
        }
    }

    /// The application layer: a Distributed Mandelbrot message.
    private func mandelbrot(_ reading: MandelbrotReading) -> Widget {
        let section = Box(.vertical, spacing: 6) {
            Separator()
            Box(.horizontal, spacing: 6) {
                Icon("view-grid-symbolic")
                Label(MandelbrotProtocol.portName(reading.port) ?? "Mandelbrot", style: "heading")
            }
            .margin(top: 6)
        }
        switch reading.message {
        case .success(let message):
            section.append(Label(message.summary(to: reading.to)).wrap().selectable())
            let fields = Grid(rowSpacing: 4, columnSpacing: 10)
            for (index, field) in message.fields.enumerated() {
                fields.attach(Label(field.label, style: "dim-label").align(vertical: GTK_ALIGN_START), column: 0, row: Int32(index))
                fields.attach(Label(field.value).wrap().selectable().expand(horizontal: true), column: 1, row: Int32(index))
            }
            section.append(fields)
        case .failure(let error):
            section.append(Box(.horizontal, spacing: 8) {
                Icon("dialog-warning-symbolic").style("warning").align(vertical: GTK_ALIGN_START)
                Label("Not a Distributed Mandelbrot message: \(error.description)").wrap().style("warning").expand(horizontal: true)
            })
        }
        return section
    }

    /// Offset, sixteen bytes in hex, and as text.
    static func dump(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: min(bytes.count, 65536), by: 16).map { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(row.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%06X  ", offset) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + " " + ascii
        }.joined(separator: "\n")
    }

    // MARK: Export

    private func export() {
        let name = session.project.name
        let frames = frames
        InternetJSONSave.choose(suggestedName: "\(name) traffic.json", title: "Export Traffic") { url in
            guard let url else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let capture = TrafficCapture(network: name, cyclesPerSecond: 2_000_000, frames: frames)
                try encoder.encode(capture).write(to: url, options: .atomic)
            } catch {
                Platform.showError(error)
            }
        }
    }
}

/// The frames listed (GtkColumnView), newest first, by frame number: new
/// ones go in at the top and old ones out at the bottom, so the one chosen
/// stays chosen as they pass.
@MainActor
private final class FrameList {
    let view: Widget
    /// The frames' ids, as strings (GtkStringObjects).
    private let store: OpaquePointer
    private let selection: OpaquePointer
    private(set) var ids: [Int] = []
    private var chosen: Int?
    private var quiet = false
    var onSelect: ((Int?) -> Void)?

    init() {
        store = cast(gtk_string_list_new(nil)!)
        let single = gtk_single_selection_new(cast(store))!
        gtk_single_selection_set_autoselect(single, 0)
        gtk_single_selection_set_can_unselect(single, 1)
        selection = cast(single)
        g_object_ref(gpointer(store))
        g_object_ref(gpointer(selection))
        view = Widget(gtk_column_view_new(cast(single))!)
        gtk_column_view_set_show_column_separators(cast(view.widget), 0)
        gtk_column_view_set_reorderable(cast(view.widget), 0)
        view.style("data-table")
        GObjectRef(selection).onChange("selected-item") { [weak self] in self?.selectionChanged() }
    }

    isolated deinit {
        g_object_unref(gpointer(selection))
        g_object_unref(gpointer(store))
    }

    private static func id(_ item: gpointer?) -> Int? {
        guard let item, let object = macbeeb_string_object(item) else { return nil }
        return Int(String(cString: gtk_string_object_get_string(object)))
    }

    typealias Cell = @MainActor (OpaquePointer) -> Void

    /// A column: `setup` makes a cell's widget, `bind` shows a frame (by
    /// id) in it.
    func column(_ title: String, width: Int32 = -1, expand: Bool = false,
                setup: @escaping @MainActor () -> WidgetPointer,
                _ bind: @escaping @MainActor (WidgetPointer, Int) -> Void) {
        let factory = gtk_signal_list_item_factory_new()!
        let made: Cell = { item in gtk_list_item_set_child(item, setup()) }
        let shown: Cell = { item in
            guard let child = gtk_list_item_get_child(item), let id = Self.id(gtk_list_item_get_item(item)) else { return }
            bind(child, id)
        }
        for (signal, body) in [("setup", made), ("bind", shown)] {
            macbeeb_signal_connect(gpointer(factory), signal, unsafeBitCast(
                { (_: gpointer?, item: gpointer?, data: gpointer?) in
                    nonisolated(unsafe) let item = item, data = data
                    MainActor.assumeIsolated {
                        guard let item else { return }
                        Boxed<Cell>.from(data)(OpaquePointer(item))
                    }
                } as @convention(c) (gpointer?, gpointer?, gpointer?) -> Void, to: GCallback.self),
                Boxed<Cell>(body).retained, { data, _ in AnyBox.release(data) }, 0)
        }
        let column = gtk_column_view_column_new(title, factory)!
        gtk_column_view_column_set_expand(column, expand ? 1 : 0)
        gtk_column_view_column_set_resizable(column, 1)
        if width > 0 { gtk_column_view_column_set_fixed_width(column, width) }
        gtk_column_view_append_column(cast(view.widget), column)
        g_object_unref(gpointer(column))
    }

    /// Newer frames, newest first, at the top (kept in view if the top
    /// was).
    func prepend(_ newer: [Int]) {
        guard !newer.isEmpty else { return }
        let atTop = scrolledToTop
        ids.insert(contentsOf: newer, at: 0)
        withCStringArray(newer.map(String.init)) { gtk_string_list_splice(store, 0, 0, $0) }
        if atTop {
            gtk_column_view_scroll_to(cast(view.widget), 0, nil, GTK_LIST_SCROLL_NONE, nil)
        }
    }

    /// Whether the list is scrolled to the top (or doesn't scroll).
    private var scrolledToTop: Bool {
        guard let adjustment = gtk_scrollable_get_vadjustment(cast(view.widget)) else { return true }
        return gtk_adjustment_get_value(adjustment) <= gtk_adjustment_get_lower(adjustment) + 1
    }

    /// Frames before `id` gone (from the bottom).
    func removeOlder(than id: Int) {
        guard let cut = ids.firstIndex(where: { $0 < id }) else { return }
        let count = ids.count - cut
        ids.removeLast(count)
        gtk_string_list_splice(store, guint(cut), guint(count), nil)
    }

    /// Different frames (a filter changed), keeping the one chosen if it's
    /// still there.
    func replace(_ new: [Int]) {
        let keep = chosen
        quiet = true
        let old = ids.count
        ids = new
        withCStringArray(new.map(String.init)) { gtk_string_list_splice(store, 0, guint(old), $0) }
        if let keep, let position = new.firstIndex(of: keep) {
            gtk_single_selection_set_selected(cast(selection), guint(position))
        }
        quiet = false
        selectionChanged()
    }

    /// Shows the rows again (names changed, say).
    func refresh() {
        let keep = ids
        replace(keep)
    }

    private func selectionChanged() {
        guard !quiet else { return }
        let id = Self.id(gtk_single_selection_get_selected_item(cast(selection)))
        guard id != chosen else { return }
        chosen = id
        onSelect?(id)
    }
}
