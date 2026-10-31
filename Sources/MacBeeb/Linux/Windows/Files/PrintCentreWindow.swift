import BeebPrint
import CGtk
import Foundation

/// The Print Centre (Network > Print Centre): every job the BBCs have
/// printed, on paper as the printer would have put it, with PDF export and
/// printing. (The Mac's PrintCentreWindow.)
@MainActor
final class PrintCentreWindow {
    static func show() {
        watchArrivals()
        Windows.show(PrintCentre.windowID) { PrintCentreWindow().window }
    }

    // MARK: Coming forward

    private static var arrivals: Tracking?
    private static var arrivalsSeen = 0

    /// Brings the Print Centre forward when a job arrives, opening it if
    /// need be. (Once is enough; at startup, so it works before the window's
    /// first opened.)
    static func watchArrivals() {
        guard arrivals == nil else { return }
        arrivalsSeen = PrintCentre.shared.arrivals
        arrivals = Tracking {
            let count = PrintCentre.shared.arrivals
            guard count != arrivalsSeen else { return }
            arrivalsSeen = count
            // (Not while tracking: opening the window reads the centre.)
            Task { @MainActor in show() }
        }
    }

    // MARK: The window

    let window: Window
    private var centre: PrintCentre { .shared }
    private let root = Stack()

    // The jobs.
    private let list = ListBox(selection: GTK_SELECTION_SINGLE)
    private var rows: [UUID: JobRow] = [:]
    private var rowOrder: [UUID] = []
    private var pageCounts: [UUID: (bytes: Int, settings: PrintSettings, pages: Int)] = [:]
    private var syncing = false
    private var focused = false
    private let rowMenu = Menu {}
    private lazy var rowPopover = Popover(menu: rowMenu)

    // The job shown.
    private let jobTitle = WindowTitle("Print Centre")
    private let detail = Stack()
    private let styleGroup: ToggleGroup
    private let paperRow: ComboRow
    private let lineFeedRow: SwitchRow
    private let pageSetup = MenuButton(icon: "document-page-setup-symbolic")
    private let jobMenu = MenuButton(icon: "view-more-symbolic")
    private let rawBytes = ToggleButton("Raw Bytes")
    private let bytesView = TextView(monospace: true)
    private let zoomLabel = Button("100%")
    private var actions: [String: Action] = [:]

    // Its pages.
    private let pageStore: OpaquePointer = cast(gtk_string_list_new(nil)!)
    private var pageList: Widget!
    private let pageScroller = ScrolledWindow()
    private var cells: [OpaquePointer: PageCell] = [:]
    private var printout: Printout?
    private var shownJob: UUID?
    private var shownBytes = -1
    private var shownSettings: PrintSettings?
    private var shownPages = 0
    private var dumpedBytes = -1
    private var zoom = 1.0
    private var showingBytes = false

    final class PageCell {
        let area: DrawingArea
        var index = -1
        init(_ area: DrawingArea) { self.area = area }
    }

    private init() {
        FilesStyles.install()
        window = Window(title: "Print Centre", width: 1000, height: 760)
        window.minimumSize(width: 760, height: 520)
        styleGroup = ToggleGroup(PrintSettings.Style.allCases.map(\.displayName),
                                 selected: PrintSettings.Style.allCases.firstIndex(of: PrintCentre.shared.settings.style) ?? 0) { index in
            let style = PrintSettings.Style.allCases[index]
            if PrintCentre.shared.settings.style != style { PrintCentre.shared.settings.style = style }
        }
        paperRow = ComboRow("Paper", subtitle: "The paper it's printed on",
                            items: PrintSettings.Paper.allCases.map(\.displayName),
                            selected: PrintSettings.Paper.allCases.firstIndex(of: PrintCentre.shared.settings.paper) ?? 0) { index in
            let paper = PrintSettings.Paper.allCases[index]
            if PrintCentre.shared.settings.paper != paper { PrintCentre.shared.settings.paper = paper }
        }
        lineFeedRow = SwitchRow("Auto Line Feed",
                                subtitle: "A carriage return also feeds a line, as a printer set up for the BBC does",
                                isOn: PrintCentre.shared.settings.autoLineFeed) { on in
            if PrintCentre.shared.settings.autoLineFeed != on { PrintCentre.shared.settings.autoLineFeed = on }
        }

        buildActions()
        let empty = ToolbarView(content: StatusPage(
            icon: "printer-symbolic", title: "Nothing Printed",
            description: "On a BBC, *FX5,1 then VDU 2 sends what's printed to its printer (VDU 3 stops). On a network, *FX5,4 sends it to the printer server."))
            .top(HeaderBar(title: WindowTitle("Print Centre")))
        let split = NavigationSplitView(sidebar: buildSidebar(), sidebarTitle: "Print Centre",
                                        content: buildDetail(), contentTitle: "Job")
            .sidebarWidth(minimum: 240, maximum: 340, fraction: 0.28)
        root.add(empty, name: "empty")
        root.add(split, name: "jobs")
        window.content = root

        App.addStandardShortcuts(to: window)
        window.shortcut("<Control>p", action: "win.print")
        window.shortcut("<Control>plus", action: "win.zoom-in")
        window.shortcut("<Control>equal", action: "win.zoom-in")
        window.shortcut("<Control>minus", action: "win.zoom-out")
        window.shortcut("<Control>0", action: "win.actual-size")
        window.track { [weak self] in self?.updateList() }
        window.track { [weak self] in self?.updateDetail() }
        window.keep(self)
        FilesSelfTest.run { [weak self] verb, argument in await self?.selfTest(verb, argument) }
    }

    // MARK: Actions

    private func command(_ name: String, _ body: @escaping @MainActor () -> Void) {
        actions[name] = window.action(name, body)
    }

    private var selectedJob: PrintJob? { centre.job(centre.selection) }

    private func buildActions() {
        let centre = centre
        command("export-pdf") { [weak self] in
            if let job = self?.selectedJob { centre.exportPDF(job) }
        }
        command("save-raw") { [weak self] in
            if let job = self?.selectedJob { centre.saveRawBytes(job) }
        }
        command("print") { [weak self] in
            guard let self, let job = self.selectedJob else { return }
            DesktopPrinting.print(job, over: self.window)
        }
        command("delete-job") { [weak self] in
            if let job = self?.selectedJob { centre.remove(job.id) }
        }
        command("clear") { [weak self] in self?.confirmClear() }
        let raw = Action(toggle: "raw-bytes", isOn: false) { [weak self] on in
            guard let self else { return }
            self.actions["raw-bytes"]?.isOn = on
            self.showingBytes = on
            self.updateDetail()
        }
        actions["raw-bytes"] = window.add(raw)
        command("zoom-in") { [weak self] in self?.setZoom((self?.zoom ?? 1) * 1.25) }
        command("zoom-out") { [weak self] in self?.setZoom((self?.zoom ?? 1) / 1.25) }
        command("actual-size") { [weak self] in self?.setZoom(1) }
        command("close") { [weak self] in self?.window.close() }
        // A job's own, from its context menu.
        window.parameterAction("export-pdf-for") { id in
            if let job = centre.job(UUID(uuidString: id)) { centre.exportPDF(job) }
        }
        window.parameterAction("save-raw-for") { id in
            if let job = centre.job(UUID(uuidString: id)) { centre.saveRawBytes(job) }
        }
        window.parameterAction("print-for") { [weak self] id in
            guard let self, let job = centre.job(UUID(uuidString: id)) else { return }
            DesktopPrinting.print(job, over: self.window)
        }
        window.parameterAction("delete-for") { id in
            if let id = UUID(uuidString: id) { centre.remove(id) }
        }
    }

    private func confirmClear() {
        AlertDialog("Delete every print job?")
            .response("cancel", "_Cancel")
            .response("delete", "_Delete All", .destructive)
            .defaults(default: "cancel", close: "cancel")
            .choose(over: window) { [weak self] response in
                if response == "delete" { self?.centre.removeAll() }
                _ = self
            }
    }

    // MARK: The jobs

    private func buildSidebar() -> Widget {
        list.style("navigation-sidebar")
        list.accessibleLabel("Print jobs")
        list.onSelect { [weak self] index in
            guard let self, !self.syncing, let index, self.rowOrder.indices.contains(index) else { return }
            let id = self.rowOrder[index]
            if self.centre.selection != id { self.centre.selection = id }
        }
        list.onContextClick { [weak self] x, y in self?.showRowMenu(x: x, y: y) }
        list.filesShortcut("Delete", action: "win.delete-job").filesShortcut("KP_Delete", action: "win.delete-job")
        let clear = Button(icon: "user-trash-symbolic").action("win.clear")
            .tooltip("Delete every job").accessibleLabel("Clear")
        let header = HeaderBar(title: WindowTitle("Print Centre")).end(clear)
        return ToolbarView(content: ScrolledWindow(list, horizontal: GTK_POLICY_NEVER).expand()).top(header)
    }

    private func pages(_ job: PrintJob) -> Int {
        guard !job.bytes.isEmpty else { return 0 }
        let settings = centre.settings
        if let cached = pageCounts[job.id], cached.bytes == job.bytes.count, cached.settings == settings {
            return cached.pages
        }
        let count = centre.printout(job).pageCount
        pageCounts[job.id] = (job.bytes.count, settings, count)
        return count
    }

    private func updateList() {
        let jobs = centre.jobs
        let ids = jobs.map(\.id)
        syncing = true
        defer { syncing = false }
        if ids != rowOrder {
            // (New rows: the old ones go with the list's.)
            rowOrder = ids
            list.removeAll()
            rows = [:]
            for job in jobs {
                let row = JobRow()
                rows[job.id] = row
                list.append(row.widget)
            }
            pageCounts = pageCounts.filter { rows[$0.key] != nil }
        }
        for job in jobs {
            rows[job.id]?.update(job, pages: pages(job))
        }
        let index = centre.selection.flatMap { ids.firstIndex(of: $0) }
        if list.selectedIndex != index { list.select(index) }
        root.visible = jobs.isEmpty ? "empty" : "jobs"
        if !jobs.isEmpty, !focused {
            // The keyboard starts in the list (up and down go through it).
            focused = true
            list.grabFocus()
        }
        actions["clear"]?.isEnabled = !jobs.isEmpty
    }

    private func showRowMenu(x: Double, y: Double) {
        guard let row = gtk_list_box_get_row_at_y(cast(list.widget), Int32(y)) else { return }
        let index = Int(gtk_list_box_row_get_index(row))
        guard rowOrder.indices.contains(index) else { return }
        let id = rowOrder[index].uuidString
        rowMenu.set([
            MenuSection {
                MenuItem("Export PDF…", "win.export-pdf-for", target: id)
                MenuItem("Save Raw Bytes…", "win.save-raw-for", target: id)
                MenuItem("Print…", "win.print-for", target: id)
            },
            MenuSection {
                MenuItem("Delete", "win.delete-for", target: id)
            },
        ])
        rowPopover.show(on: list, at: x, y: y)
    }

    // MARK: The job shown

    private func buildDetail() -> Widget {
        styleGroup.tooltip("Clean type, or dots as a dot-matrix printer makes them").accessibleLabel("Style")
        let setupList = ListBox().style("boxed-list")
        setupList.append(paperRow)
        setupList.append(lineFeedRow)
        pageSetup.popover(Box(.vertical) { setupList }.margin(6).size(width: 380))
        pageSetup.tooltip("Paper and line feeds").accessibleLabel("Page Setup")
        jobMenu.menu = Menu {
            MenuSection {
                MenuItem("Export PDF…", "win.export-pdf")
                MenuItem("Save Raw Bytes…", "win.save-raw")
                MenuItem("Print…", "win.print", accel: "<Control>p")
            }
            MenuSection {
                MenuItem("Zoom In", "win.zoom-in", accel: "<Control>plus")
                MenuItem("Zoom Out", "win.zoom-out", accel: "<Control>minus")
                MenuItem("Actual Size", "win.actual-size", accel: "<Control>0")
            }
            MenuSection {
                MenuItem("Delete", "win.delete-job", accel: "Delete")
            }
        }
        jobMenu.tooltip("More").accessibleLabel("More")
        rawBytes.action("win.raw-bytes").tooltip("The bytes exactly as the BBC sent them").accessibleLabel("Raw Bytes")
        let export = Button(icon: "document-save-as-symbolic").action("win.export-pdf")
            .tooltip("Save the printout as a PDF").accessibleLabel("Export PDF")
        let print = Button(icon: "printer-symbolic").action("win.print")
            .tooltip("Print it on this computer’s printer").accessibleLabel("Print")
        let header = HeaderBar(title: jobTitle).start(styleGroup).start(pageSetup)
            .end(jobMenu).end(print).end(export).end(rawBytes)

        detail.add(buildPages(), name: "pages")
        bytesView.margins(12)
        gtk_text_view_set_wrap_mode(cast(bytesView.widget), GTK_WRAP_NONE)
        bytesView.accessibleLabel("Raw bytes")
        detail.add(ScrolledWindow(bytesView).expand(), name: "bytes")
        detail.add(StatusPage(icon: "x-office-document-symbolic", title: "No Job Selected"), name: "none")
        return ToolbarView(content: detail).top(header)
    }

    /// The pages, one under another on the desk (made as they're scrolled
    /// to: a job can be thousands).
    private func buildPages() -> Widget {
        let factory = gtk_signal_list_item_factory_new()!
        typealias Item = @MainActor (OpaquePointer) -> Void
        let setup: Item = { [weak self] item in
            guard let self else { return }
            let area = DrawingArea { _, _, _ in }
            let cell = PageCell(area)
            area.setDraw { [weak self, cell] cairo, width, height in
                self?.drawPage(cell.index, cairo, width, height)
            }
            area.style("card", "macbeeb-paper").align(horizontal: GTK_ALIGN_CENTER)
            gtk_widget_set_overflow(area.widget, GTK_OVERFLOW_HIDDEN)
            gtk_list_item_set_child(item, area.widget)
            gtk_list_item_set_activatable(item, 0)
            gtk_list_item_set_selectable(item, 0)
            gtk_list_item_set_focusable(item, 0)
            self.cells[item] = cell
        }
        let bind: Item = { [weak self] item in
            guard let self, let cell = self.cells[item],
                  let index = filesListIndex(gtk_list_item_get_item(item)) else { return }
            cell.index = index
            self.size(cell)
            cell.area.accessibleLabel("Page \(index + 1)")
            if let printout = self.printout, printout.pages.indices.contains(index) {
                macbeeb_set_accessible_description(cell.area.widget, printout.text(page: index))
            }
            cell.area.queueDraw()
        }
        let teardown: Item = { [weak self] item in
            self?.cells[item] = nil
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
        g_object_ref(gpointer(pageStore))
        let selection = gtk_no_selection_new(cast(pageStore))!
        let view = gtk_list_view_new(cast(selection), factory)!
        pageList = Widget(view).style("macbeeb-pages")
        pageList.accessibleLabel("Pages")
        pageScroller.child = pageList
        pageScroller.style("macbeeb-desk")
        pageScroller.expand()

        // Control and the wheel zooms.
        let scroll = ScrollController(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL).phase(GTK_PHASE_CAPTURE)
        scroll.onScroll { [weak self, scroll] _, dy in
            guard let self, scroll.modifiers.rawValue & GDK_CONTROL_MASK.rawValue != 0 else { return false }
            self.setZoom(self.zoom * (dy < 0 ? 1.1 : 1 / 1.1))
            return true
        }
        pageScroller.add(scroll)

        let zoomOut = Button(icon: "zoom-out-symbolic").action("win.zoom-out").tooltip("Zoom Out").accessibleLabel("Zoom Out")
        let zoomIn = Button(icon: "zoom-in-symbolic").action("win.zoom-in").tooltip("Zoom In").accessibleLabel("Zoom In")
        zoomLabel.action("win.actual-size").tooltip("Actual Size")
        gtk_widget_add_css_class(zoomLabel.widget, "numeric")
        zoomLabel.size(width: 64)
        for button in [zoomOut, zoomLabel, zoomIn] { button.style("flat") }
        let zoom = Box(.horizontal, spacing: 2) { zoomOut; zoomLabel; zoomIn }
            .style("osd", "macbeeb-zoom")
            .align(horizontal: GTK_ALIGN_END, vertical: GTK_ALIGN_END)
        return Overlay(pageScroller) { zoom }
    }

    private func size(_ cell: PageCell) {
        let paper = (printout?.settings ?? centre.settings).paper.size
        cell.area.contentSize(width: Int32((Double(paper.width) * zoom).rounded()),
                              height: Int32((Double(paper.height) * zoom).rounded()))
    }

    /// One page, drawn by the same code as the PDF.
    private func drawPage(_ index: Int, _ cairo: Cairo, _ width: Double, _ height: Double) {
        guard let printout, printout.pages.indices.contains(index) else { return }
        let paper = printout.settings.paper.size
        cairo.save()
        cairo.scale(width / Double(paper.width), height / Double(paper.height))
        // Ink on paper: no colour fringes, and type where the page puts it.
        let options = cairo_font_options_create()
        cairo_font_options_set_antialias(options, CAIRO_ANTIALIAS_GRAY)
        cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_OFF)
        cairo_set_font_options(cairo.context, options)
        cairo_font_options_destroy(options)
        printout.draw(page: index, in: cairo.context, font: centre.font)
        cairo.restore()
    }

    private func setZoom(_ value: Double) {
        let zoom = min(2, max(0.5, value))
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        zoomLabel.label = "\(Int((zoom * 100).rounded()))%"
        for cell in cells.values {
            size(cell)
            cell.area.queueDraw()
        }
        actions["zoom-in"]?.isEnabled = zoom < 2
        actions["zoom-out"]?.isEnabled = zoom > 0.5
    }

    private func updateDetail() {
        let settings = centre.settings
        styleGroup.selected = PrintSettings.Style.allCases.firstIndex(of: settings.style) ?? 0
        paperRow.selected = PrintSettings.Paper.allCases.firstIndex(of: settings.paper) ?? 0
        lineFeedRow.isOn = settings.autoLineFeed

        let job = selectedJob
        for name in ["export-pdf", "save-raw", "print", "delete-job", "raw-bytes"] {
            actions[name]?.isEnabled = job != nil
        }
        styleGroup.isEnabled = job != nil
        guard let job else {
            jobTitle.title = "Print Centre"
            jobTitle.subtitle = ""
            detail.visible = "none"
            shownJob = nil
            return
        }

        let newJob = job.id != shownJob
        if newJob || job.bytes.count != shownBytes || settings != shownSettings {
            let printout = centre.printout(job)
            self.printout = printout
            let count = printout.pageCount
            if newJob || settings != shownSettings || count < shownPages {
                spliceIndices(pageStore, count: count)
                if newJob {
                    // (Each job from its first page.)
                    gtk_adjustment_set_value(gtk_scrolled_window_get_vadjustment(cast(pageScroller.widget)), 0)
                }
            } else if count > shownPages {
                spliceIndices(pageStore, count: count, from: shownPages)
            }
            // While it prints, the page being printed.
            if !newJob, job.status == .printing, count > shownPages, count > 0 {
                gtk_list_view_scroll_to(cast(pageList.widget), guint(count - 1), GTK_LIST_SCROLL_NONE, nil)
            }
            for cell in cells.values {
                size(cell)
                cell.area.queueDraw()
            }
            shownJob = job.id
            shownBytes = job.bytes.count
            shownSettings = settings
            shownPages = count
        }

        let pages = shownPages
        var subtitle = (job.source.map { "From \($0) · " } ?? "") + "\(pages) page\(pages == 1 ? "" : "s")"
        var tooltip: String?
        if let printout, !printout.unsupported.isEmpty {
            let codes = printout.unsupported.values.reduce(0, +)
            subtitle += " · \(codes) code\(codes == 1 ? "" : "s") not drawn"
            tooltip = "Printer codes MacBeeb doesn't draw (they're kept in the job): "
                + printout.unsupported.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        }
        jobTitle.title = job.printer
        jobTitle.subtitle = subtitle
        jobTitle.tooltip(tooltip)

        if showingBytes {
            if dumpedBytes != job.bytes.count || newJob {
                bytesView.text = Self.dump(job.bytes)
                dumpedBytes = job.bytes.count
            }
            detail.visible = "bytes"
        } else {
            dumpedBytes = -1
            detail.visible = "pages"
        }
    }

    /// The bytes as a hex dump, 16 a line, with their characters.
    static func dump(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: min(bytes.count, 65536), by: 16).map { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(row.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%06X  ", offset) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + " " + ascii
        }.joined(separator: "\n")
    }

    // MARK: Self-tests

    private func selfTest(_ verb: String, _ argument: String) async {
        switch verb {
        case "job":
            // A job as a BBC would send it: CRs, a bold title, a form feed.
            var bytes: [UInt8] = [27, UInt8(ascii: "E")] + Array("MACBEEB PRINT CENTRE".utf8) + [27, UInt8(ascii: "F"), 13]
            bytes += [27, UInt8(ascii: "-"), 1] + Array("Underlined".utf8) + [27, UInt8(ascii: "-"), 0, 13, 13]
            for line in stride(from: 10, through: Int(argument) ?? 90, by: 10) {
                bytes += Array("\(line) PRINT \"HELLO WORLD \";\(line)*7".utf8) + [13]
            }
            bytes += [27, UInt8(ascii: "x"), 1, 12] + Array(">RUN".utf8) + [13]
            var job = PrintJob(printer: "BBC Model B", started: Date())
            job.bytes = bytes
            job.status = .finished
            job.finished = Date()
            centre.update(job)
        case "printing":
            var job = PrintJob(printer: "Printer server (station 235)", source: "station 1", started: Date())
            job.bytes = Array("LISTING IN PROGRESS\r".utf8)
            centre.update(job)
        case "type":
            // VDU 2 on the frontmost machine.
            (MachineController.frontmost ?? MachineController.all.values.first)?.host.send(.type(argument.isEmpty ? "VDU2:PRINT \"HELLO\":VDU3\n" : argument + "\n"))
        case "select":
            if let index = Int(argument), centre.jobs.indices.contains(index) { centre.selection = centre.jobs[index].id }
        case "style":
            centre.settings.style = argument == "clean" ? .clean : .dotMatrix
        case "paper":
            centre.settings.paper = PrintSettings.Paper(rawValue: argument) ?? .a4
        case "zoom":
            setZoom(Double(argument) ?? 1)
        case "bytes":
            gtk_widget_activate_action_variant(window.widget, "win.raw-bytes", nil)
        case "setup":
            pageSetup.popup()
            try? await Task.sleep(for: .milliseconds(600))
            FilesSelfTest.capture(gtk_menu_button_get_popover(cast(pageSetup.widget)).map { cast($0) }, as: "setup")
        case "menu":
            showRowMenu(x: 100, y: 30)
            try? await Task.sleep(for: .milliseconds(600))
            FilesSelfTest.capture(rowPopover.widget, as: "menu")
        case "more":
            jobMenu.popup()
            try? await Task.sleep(for: .milliseconds(600))
            FilesSelfTest.capture(gtk_menu_button_get_popover(cast(jobMenu.widget)).map { cast($0) }, as: "more")
        case "clear":
            confirmClear()
        case "export-print":
            // The print operation, to a PDF (no dialog).
            if let job = selectedJob {
                DesktopPrinting.print(job, over: window, exportingTo: URL(fileURLWithPath: argument))
            }
        case "pdf":
            if let job = selectedJob {
                try? centre.printout(job).pdf(font: centre.font, title: centre.title(job)).write(to: URL(fileURLWithPath: argument))
            }
        case "dump":
            FilesSelfTest.log("jobs: " + centre.jobs.map { "\($0.printer) \($0.bytes.count) bytes \($0.status)" }.joined(separator: ", "))
        case "remove-all":
            centre.removeAll()
        default:
            FilesSelfTest.log("unknown step \(verb)")
        }
    }
}

/// A job in the list: its printer, when, how long, and how it ended.
@MainActor
final class JobRow {
    let widget: Box
    private let printer = Label("", style: "heading")
    private let started = Label("", style: "caption", "dim-label")
    private let size = Label("", style: "caption", "dim-label", "numeric")
    private let status = Icon("printer-printing-symbolic")

    init() {
        let printer = printer, status = status, started = started, size = size
        printer.ellipsize().expand(horizontal: true)
        started.ellipsize()
        size.ellipsize()
        widget = Box(.vertical, spacing: 3) {
            Box(.horizontal, spacing: 6) { printer; status }
            started
            size
        }
        widget.style("macbeeb-job-row")
    }

    func update(_ job: PrintJob, pages: Int) {
        printer.text = job.printer
        started.text = job.started.formatted(date: .abbreviated, time: .standard)
        size.text = "\(pages) page\(pages == 1 ? "" : "s") · \(job.bytes.count) bytes"
        for name in ["success", "warning"] { status.removeStyle(name) }
        var state = ""
        switch job.status {
        case .printing:
            status.name = "printer-printing-symbolic"
            status.style("success")
            status.tooltip("Still printing")
            state = "Still printing"
        case .finished:
            break
        case .interrupted:
            status.name = "dialog-warning-symbolic"
            status.style("warning")
            status.tooltip("The machine stopped part way through: this is what arrived")
            state = "Interrupted"
        case .truncated:
            status.name = "edit-cut-symbolic"
            status.style("warning")
            status.tooltip("Over \(PrintJob.limit / 1024 / 1024)MB: the rest wasn't kept")
            state = "Too long"
        }
        status.isVisible = job.status != .finished
        // (The list's row, around it, is what's read out.)
        let row = gtk_widget_get_parent(widget.widget).map(Widget.init) ?? widget
        row.accessibleLabel([job.printer, started.text, size.text, state].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

// MARK: Printing

/// Printing a job on the computer's printer, through the desktop's print
/// dialog (GtkPrintOperation): each page drawn as on screen, scaled to the
/// paper chosen.
@MainActor
enum DesktopPrinting {
    /// The printer and its settings, as last chosen.
    private static var settings: OpaquePointer?
    private static var running: [UUID: PrintRun] = [:]

    final class PrintRun {
        let operation: UnsafeMutablePointer<GtkPrintOperation>
        /// A problem's been shown (once is enough).
        var reported = false
        init(_ operation: UnsafeMutablePointer<GtkPrintOperation>) { self.operation = operation }
        deinit { g_object_unref(gpointer(operation)) }
    }

    /// Prints `job` (or, `exportingTo` a file, saves it as a PDF the same
    /// way, without a dialog).
    static func print(_ job: PrintJob, over window: Window?, exportingTo url: URL? = nil) {
        let centre = PrintCentre.shared
        let printout = centre.printout(job)
        let font = centre.font
        guard printout.pageCount > 0, let operation = gtk_print_operation_new() else { return }
        gtk_print_operation_set_job_name(operation, centre.title(job))
        gtk_print_operation_set_n_pages(operation, Int32(printout.pageCount))
        gtk_print_operation_set_unit(operation, GTK_UNIT_POINTS)
        gtk_print_operation_set_use_full_page(operation, 1)
        gtk_print_operation_set_embed_page_setup(operation, 1)
        gtk_print_operation_set_allow_async(operation, 1)
        if let settings { gtk_print_operation_set_print_settings(operation, settings) }

        // The paper it's laid out for, edge to edge (the printout has its
        // own margins).
        let size = printout.settings.paper.size
        let paper: OpaquePointer = switch printout.settings.paper {
        case .a4: gtk_paper_size_new("iso_a4")
        case .letter: gtk_paper_size_new("na_letter")
        case .fanfold: gtk_paper_size_new_custom("macbeeb_fanfold", PrintSettings.Paper.fanfold.displayName,
                                                 Double(size.width), Double(size.height), GTK_UNIT_POINTS)
        }
        let setup = gtk_page_setup_new()!
        gtk_page_setup_set_paper_size(setup, paper)
        for set in [gtk_page_setup_set_top_margin, gtk_page_setup_set_bottom_margin,
                    gtk_page_setup_set_left_margin, gtk_page_setup_set_right_margin] {
            set(setup, 0, GTK_UNIT_POINTS)
        }
        gtk_paper_size_free(paper)
        gtk_print_operation_set_default_page_setup(operation, setup)
        g_object_unref(gpointer(setup))

        GObjectRef(operation).onPointerInt("draw-page") { context, page in
            guard let context else { return }
            let printContext = OpaquePointer(context)
            guard let cairo = gtk_print_context_get_cairo_context(printContext) else { return }
            let width = gtk_print_context_get_width(printContext), height = gtk_print_context_get_height(printContext)
            let scale = min(width / Double(size.width), height / Double(size.height))
            cairo_save(cairo)
            cairo_translate(cairo, (width - Double(size.width) * scale) / 2, (height - Double(size.height) * scale) / 2)
            cairo_scale(cairo, scale, scale)
            printout.draw(page: Int(page), in: cairo, font: font)
            cairo_restore(cairo)
        }

        let id = UUID()
        running[id] = PrintRun(operation)
        GObjectRef(operation).onEnum("done") { result in
            finished(id, operation, result: GtkPrintOperationResult(rawValue: result))
        }
        if let url {
            gtk_print_operation_set_export_filename(operation, url.path)
        }
        var error: UnsafeMutablePointer<GError>?
        let result = gtk_print_operation_run(operation, url == nil ? GTK_PRINT_OPERATION_ACTION_PRINT_DIALOG
                                                                   : GTK_PRINT_OPERATION_ACTION_EXPORT,
                                             window?.window, &error)
        if let error {
            let message = String(cString: error.pointee.message)
            g_error_free(error)
            report(id, message)
        }
        if result != GTK_PRINT_OPERATION_RESULT_IN_PROGRESS {
            // (Done already, or never started.)
            MainLoop.after(0) { running[id] = nil }
        }
    }

    private static func finished(_ id: UUID, _ operation: UnsafeMutablePointer<GtkPrintOperation>,
                                 result: GtkPrintOperationResult) {
        if result == GTK_PRINT_OPERATION_RESULT_APPLY, let chosen = gtk_print_operation_get_print_settings(operation) {
            g_object_ref(gpointer(chosen))
            if let settings { g_object_unref(gpointer(settings)) }
            settings = chosen
        } else if result == GTK_PRINT_OPERATION_RESULT_ERROR {
            var error: UnsafeMutablePointer<GError>?
            gtk_print_operation_get_error(operation, &error)
            let message = error.map { String(cString: $0.pointee.message) } ?? "The printer reported a problem."
            report(id, message)
        }
        // (Not while it's signalling.)
        MainLoop.after(0) { running[id] = nil }
    }

    private static func report(_ id: UUID, _ message: String) {
        guard let run = running[id], !run.reported else { return }
        run.reported = true
        Platform.showAlert(title: "The job couldn’t be printed", message: message)
    }
}

// MARK: Signals and actions (of shapes the GTK layer's helpers haven't got)

fileprivate extension GObjectRef {
    /// `void handler(instance, pointer, int, data)` (GtkPrintOperation's
    /// draw-page).
    @MainActor
    @discardableResult
    func onPointerInt(_ signal: String, _ body: @escaping @MainActor (gpointer?, Int32) -> Void) -> gulong {
        typealias Handler = @MainActor (gpointer?, Int32) -> Void
        return macbeeb_signal_connect(pointer, signal, unsafeBitCast(
            { (_: gpointer?, argument: gpointer?, value: gint, data: gpointer?) in
                nonisolated(unsafe) let argument = argument, data = data
                MainActor.assumeIsolated { Boxed<Handler>.from(data)(argument, value) }
            } as @convention(c) (gpointer?, gpointer?, gint, gpointer?) -> Void, to: GCallback.self),
            Boxed<Handler>(body).retained, { data, _ in AnyBox.release(data) }, 0)
    }

    /// `void handler(instance, enum, data)` (GtkPrintOperation's done).
    @MainActor
    @discardableResult
    func onEnum(_ signal: String, _ body: @escaping @MainActor (UInt32) -> Void) -> gulong {
        typealias Handler = @MainActor (UInt32) -> Void
        return macbeeb_signal_connect(pointer, signal, unsafeBitCast(
            { (_: gpointer?, value: guint, data: gpointer?) in
                nonisolated(unsafe) let data = data
                MainActor.assumeIsolated { Boxed<Handler>.from(data)(value) }
            } as @convention(c) (gpointer?, guint, gpointer?) -> Void, to: GCallback.self),
            Boxed<Handler>(body).retained, { data, _ in AnyBox.release(data) }, 0)
    }
}

fileprivate extension Window {
    /// A window action with a string parameter, for menu items naming what
    /// they act on (`MenuItem("Delete", "win.delete-job", target: id)`): a
    /// command, not a choice (so no radio marks).
    func parameterAction(_ name: String, _ body: @escaping @MainActor (String) -> Void) {
        let gAction = g_simple_action_new(name, macbeeb_variant_type_string())!
        GObjectRef(gAction).onPointer("activate") { parameter in
            guard let parameter else { return }
            body(String(cString: g_variant_get_string(OpaquePointer(parameter), nil)))
        }
        g_action_map_add_action(OpaquePointer(widget), gAction)
        g_object_unref(gpointer(gAction))
    }
}

/// A list's model of rows 0..<count, as strings.
@MainActor
fileprivate func spliceIndices(_ store: OpaquePointer, count: Int, from start: Int = 0) {
    let existing = Int(g_list_model_get_n_items(cast(store)))
    let items = (start..<count).map(String.init)
    withCStringArray(items) { strings in
        gtk_string_list_splice(cast(store), guint(min(start, existing)), guint(max(0, existing - start)), strings)
    }
}
