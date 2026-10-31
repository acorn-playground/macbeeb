import BeebHost
import BeebNetwork
import CGtk
import Foundation

/// One machine, live and full size enough to use: its name and number, and
/// its screen, which takes the keyboard when it's clicked.
@MainActor
final class StationTileView {
    let id: UUID
    let controller: MachineController
    let widget: Widget
    let emulator: EmulatorArea
    private let speaker: Icon
    private let name: String

    init(session: NetworkSession, node: NetworkNode, controller: MachineController, openStation: @escaping (UUID) -> Void) {
        let speaker = Icon("audio-volume-high-symbolic", size: 14)
        self.speaker = speaker
        id = node.id
        self.controller = controller
        name = node.name
        emulator = EmulatorArea(host: controller.host)
        emulator.area.size(width: 160, height: 120)
        emulator.keyboardDisc = { [weak controller] in controller?.bootDiscPath }
        let id = node.id
        emulator.onFocus = { [weak controller] in
            session.focus(id)
            if let controller { Joysticks.shared.machine = controller }
        }
        let title = Label(node.name, style: "heading").ellipsize()
        let summary = Label(node.setup?.summary ?? "", style: "caption", "dim-label").ellipsize().maxWidthChars(1)
        summary.expand(horizontal: true)
        speaker.style("dim-label").tooltip("Heard").accessibleLabel("Heard")
        let open = Button(icon: "window-new-symbolic") { openStation(id) }
            .style("flat", "circular")
            .tooltip("Open in its own window")
            .accessibleLabel("Open \(node.name) in its own window")
        let header = Box(.horizontal, spacing: 6) {
            StationNumberBadge(node.stationNumber)
            title
            summary
            speaker
            open
        }
        header.margin(top: 4, bottom: 4, start: 8, end: 4)
        let screen = Bin(emulator.area).style("network-tile-screen").expand()
        gtk_widget_set_overflow(screen.widget, GTK_OVERFLOW_HIDDEN)
        let tile = Box(.vertical) {
            header
            screen
        }
        tile.style("network-tile")
        gtk_widget_set_overflow(tile.widget, GTK_OVERFLOW_HIDDEN)
        widget = tile
        let area = emulator
        tile.track { [area] in
            area.renderer.style = controller.displayStyle
            area.renderer.monitor = controller.monitor
            area.redraw()
        }
        tile.keep(self)
    }

    /// The one with the keyboard: a ring round it, heard, and typed into.
    func setFocused(_ focused: Bool, takeKeyboard: Bool) {
        widget.setStyle("focused", focused)
        speaker.isVisible = focused
        widget.accessibleLabel("\(name)\(focused ? ", has the keyboard" : "")")
        if focused && takeKeyboard && !emulator.area.hasFocus {
            emulator.area.grabFocus()
        }
    }
}

/// The machines side by side, each live and full size enough to use. The
/// one with the keyboard has a ring round it, and it's the one heard.
@MainActor
final class NetworkTilesView {
    let session: NetworkSession
    let root: Widget
    private let openStation: (UUID) -> Void
    private let content = Stack()
    private let grid = Grid(rowSpacing: 10, columnSpacing: 10)
    private let sizer: DrawingArea
    private var tiles: [UUID: StationTileView] = [:]
    private var order: [UUID] = []
    private var key = ""
    private var mapped = false
    private var size = (width: 0.0, height: 0.0)
    private let keyboardLabel = Label("", style: "dim-label")

    init(session: NetworkSession, openStation: @escaping (UUID) -> Void) {
        self.session = session
        self.openStation = openStation
        sizer = DrawingArea { _, _, _ in }
        sizer.expand()
        grid.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_START).margin(10)
        let scroller = ScrolledWindow(grid, horizontal: GTK_POLICY_NEVER)
        let tilesPage = Overlay(sizer) { scroller }
        content.add(tilesPage, name: "tiles")
        content.add(noMachinesOn(session), name: "empty")
        let box = Box(.vertical)
        box.style("network-backdrop")
        root = box
        box.append(tileBar())
        box.append(Separator())
        box.append(content.expand())

        sizer.object.onSize("resize") { [self] width, height in
            self.size = (Double(width), Double(height))
            self.sizeTiles()
        }
        root.onMap { [self] in
            self.mapped = true
            self.key = ""
            self.refresh()
        }
        root.onUnmap { [self] in
            self.mapped = false
            self.clear()
        }
        root.track { [self] in
            _ = session.project.stations
            _ = session.project.workspace
            _ = session.controllers
            self.refresh()
        }
        root.track { [self] in
            let focused = session.focused
            for (id, tile) in self.tiles {
                tile.setFocused(id == focused, takeKeyboard: true)
            }
            self.keyboardLabel.text = focused.flatMap { session.node($0) }.map { "\($0.name) has the keyboard" } ?? ""
            self.keyboardLabel.isVisible = focused != nil
        }
        root.keep(self)
    }

    private var chosen: [UUID] { session.project.workspace.tiles }

    private var shown: [NetworkNode] {
        session.project.stations.filter { session.isOn($0.id) && (chosen.isEmpty || chosen.contains($0.id)) }
    }

    /// Tiles for the machines shown, made again when they change.
    private func refresh() {
        guard mapped else { return }
        let shown = shown
        let key = shown.map { node in
            "\(node.id) \(session.controllers[node.id].map { ObjectIdentifier($0).hashValue } ?? 0)"
        }.joined(separator: ",") + " \(session.project.workspace.columns)"
        content.visible = shown.isEmpty ? "empty" : "tiles"
        guard key != self.key else { return }
        self.key = key
        clear()
        for node in shown {
            guard let controller = session.controllers[node.id] else { continue }
            let tile = StationTileView(session: session, node: node, controller: controller, openStation: openStation)
            tiles[node.id] = tile
            order.append(node.id)
            tile.setFocused(session.focused == node.id, takeKeyboard: session.focused == node.id)
        }
        sizeTiles()
    }

    private func clear() {
        grid.removeAll()
        tiles = [:]
        order = []
        key = ""
    }

    private func columnCount(_ count: Int, width: Double) -> Int {
        let chosen = session.project.workspace.columns
        if chosen > 0 { return min(chosen, max(count, 1)) }
        // As square as fits.
        let fit = max(1, Int(width / 300))
        return min(fit, max(1, Int(Double(count).squareRoot().rounded(.up))))
    }

    /// Lays the tiles out to fill the view, as many columns as chosen (or
    /// fit), each as big as fits.
    private func sizeTiles() {
        guard !order.isEmpty, size.width > 0 else { return }
        let count = order.count
        let columns = columnCount(count, width: size.width)
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let spacing = 10.0
        let width = (size.width - spacing * Double(columns + 1)) / Double(columns)
        let height = min((size.height - spacing * Double(rows + 1)) / Double(rows), width / Renderer.aspect + 34)
        let layout = gtk_widget_get_layout_manager(grid.widget)
        for (index, id) in order.enumerated() {
            guard let tile = tiles[id] else { continue }
            tile.widget.size(width: Int32(max(120, width.rounded(.down))), height: Int32(max(160, height.rounded(.down))))
            let column = Int32(index % columns), row = Int32(index / columns)
            if gtk_widget_get_parent(tile.widget.widget) == nil {
                grid.attach(tile.widget, column: column, row: row)
            } else if let child = gtk_layout_manager_get_layout_child(layout, tile.widget.widget) {
                // Moved, not taken out (which would end its screen).
                gtk_grid_layout_child_set_column(cast(child), column)
                gtk_grid_layout_child_set_row(cast(child), row)
            }
        }
    }

    private func tileBar() -> Widget {
        let session = session
        // Which machines: every one that's on, or those chosen.
        let list = Box(.vertical, spacing: 2)
        let every = Button("Every Machine That’s On") { session.update { $0.workspace.tiles = [] } }.style("flat")
        let chooser = Box(.vertical, spacing: 6) {
            every
            Separator()
            list
        }
        chooser.margin(6)
        var listed: [String] = []
        list.track { [list] in
            let chosen = session.project.workspace.tiles
            let stations = session.project.stations
            let key = stations.map { "\($0.id) \($0.name)" } + chosen.map(\.uuidString)
            guard key != listed else { return }
            listed = key
            list.removeAll()
            for node in stations {
                list.append(CheckButton(node.name, isOn: chosen.isEmpty || chosen.contains(node.id)) { on in
                    session.update { project in
                        var tiles = project.workspace.tiles.isEmpty ? project.stations.map(\.id) : project.workspace.tiles
                        if on {
                            if !tiles.contains(node.id) { tiles.append(node.id) }
                        } else {
                            tiles.removeAll { $0 == node.id }
                        }
                        project.workspace.tiles = tiles
                    }
                })
            }
        }
        let show = MenuButton(icon: "view-grid-symbolic", label: "Show").popover(chooser)
            .tooltip("Which machines the tiles show")
        let choices = [0, 2, 3, 4]
        let columns = ToggleGroup(["Fit", "2", "3", "4"], selected: choices.firstIndex(of: session.project.workspace.columns) ?? 0) { index in
            session.update { $0.workspace.columns = choices[index] }
        }
        columns.tooltip("Columns").accessibleLabel("Columns")
        columns.track { [columns] in
            columns.selected = choices.firstIndex(of: session.project.workspace.columns) ?? 0
        }
        return MachineStepper.bar(session: session, leading: [show, columns], keyboard: keyboardLabel,
                                  previous: "The previous machine gets the keyboard", next: "The next machine gets the keyboard") { forward in
            session.focusNext(forward)
        }
    }
}

/// The bar above the tiles and the focus view: its own controls, then the
/// previous and next machine, and which has the keyboard.
@MainActor
enum MachineStepper {
    static func bar(session: NetworkSession, leading: [Widget], keyboard: Label, previous: String, next: String,
                    step: @escaping @MainActor (Bool) -> Void) -> Widget {
        let back = Button(icon: "go-previous-symbolic") { step(false) }.style("flat").tooltip(previous + " (Alt+[)")
            .accessibleLabel(previous)
        let forward = Button(icon: "go-next-symbolic") { step(true) }.style("flat").tooltip(next + " (Alt+])")
            .accessibleLabel(next)
        let keyboardBox = Box(.horizontal, spacing: 6) {
            Icon("input-keyboard-symbolic").style("dim-label")
            keyboard
        }
        keyboard.track { [keyboardBox, keyboard] in keyboardBox.isVisible = keyboard.isVisible }
        keyboard.onMap { [keyboardBox, keyboard] in keyboardBox.isVisible = keyboard.isVisible }
        let bar = Box(.horizontal, spacing: 12)
        for widget in leading { bar.append(widget) }
        bar.append(NetworkRowSpacer())
        bar.append(Box(.horizontal, spacing: 2) { back; forward })
        bar.append(keyboardBox)
        bar.margin(horizontal: 12, vertical: 6)
        return bar
    }
}

/// No machines on: switch them on.
@MainActor
func noMachinesOn(_ session: NetworkSession) -> Widget {
    let button = Button("Power On All") { session.powerOnAll() }.style("pill", "suggested-action")
        .align(horizontal: GTK_ALIGN_CENTER)
    return StatusPage(icon: "system-shutdown-symbolic", title: "No Machines On",
                      description: "Switch machines on in the canvas, or with Power On All.", child: button)
}

/// One machine large, with the keyboard, and every machine that's on in a
/// strip down the left, live. Click one in the strip to make it the large
/// one; it's selected too, for the inspector.
@MainActor
final class NetworkFocusView {
    let session: NetworkSession
    let root: Widget
    private let openStation: (UUID) -> Void
    private let content = Stack()
    private let strip: Box
    private let main: Bin
    private var mainTile: StationTileView?
    private var thumbnails: [UUID: FocusThumbnail] = [:]
    private var stripKey = ""
    private var mapped = false
    private let feed: ThumbnailFeed
    private let keyboardLabel = Label("", style: "dim-label")

    static let stripWidth: Int32 = 210

    init(session: NetworkSession, openStation: @escaping (UUID) -> Void) {
        self.session = session
        self.openStation = openStation
        feed = ThumbnailFeed(session.thumbnails)
        let strip = Box(.vertical, spacing: 10)
        let main = Bin()
        self.strip = strip
        self.main = main
        strip.margin(10)
        let stripScroller = ScrolledWindow(strip, horizontal: GTK_POLICY_NEVER).size(width: Self.stripWidth)
        main.expand()
        let body = Box(.horizontal) {
            stripScroller
            Separator(GTK_ORIENTATION_VERTICAL)
            main
        }
        content.add(body, name: "focus")
        content.add(noMachinesOn(session), name: "empty")
        let box = Box(.vertical)
        box.style("network-backdrop")
        root = box
        box.append(MachineStepper.bar(session: session, leading: [Label("Click a machine to bring it here", style: "dim-label")],
                                      keyboard: keyboardLabel, previous: "Show the previous machine",
                                      next: "Show the next machine") { [self] forward in self.step(forward) })
        box.append(Separator())
        box.append(content.expand())

        root.onMap { [self] in
            self.mapped = true
            self.stripKey = ""
            self.refresh()
            if let main = self.mainMachine(among: self.on) { session.focus(main.id) }
        }
        root.onUnmap { [self] in
            self.mapped = false
            self.mainTile = nil
            self.main.child = nil
            self.strip.removeAll()
            self.thumbnails = [:]
            self.stripKey = ""
            self.feed.clear()
        }
        root.track { [self] in
            _ = session.project.stations
            _ = session.project.workspace.focus
            _ = session.focused
            _ = session.controllers
            self.refresh()
        }
        root.track { [self] in
            let images = session.thumbnails.images
            for (id, thumbnail) in self.thumbnails { thumbnail.setImage(images[id]) }
        }
        root.keep(self)
    }

    private var on: [NetworkNode] { session.project.stations.filter { session.isOn($0.id) } }

    /// The one chosen, if it's on; otherwise the one with the keyboard, or
    /// the first that's on.
    private func mainMachine(among on: [NetworkNode]) -> NetworkNode? {
        for id in [session.project.workspace.focus, session.focused].compactMap({ $0 }) {
            if let node = on.first(where: { $0.id == id }) { return node }
        }
        return on.first
    }

    private func refresh() {
        guard mapped else { return }
        let on = on
        let main = mainMachine(among: on)
        content.visible = main == nil ? "empty" : "focus"
        keyboardLabel.text = main.map { "\($0.name) has the keyboard" } ?? ""
        keyboardLabel.isVisible = main != nil
        // The strip.
        let key = on.map { "\($0.id) \($0.name) \($0.stationNumber ?? 0) \(session.controllers[$0.id].map { ObjectIdentifier($0).hashValue } ?? 0)" }
            .joined(separator: ",")
        if key != stripKey {
            stripKey = key
            strip.removeAll()
            thumbnails = [:]
            var hosts: [UUID: EmulatorHost] = [:]
            for node in on {
                guard let controller = session.controllers[node.id] else { continue }
                let thumbnail = FocusThumbnail(node: node) { [self] in self.show(node.id) }
                thumbnails[node.id] = thumbnail
                strip.append(thumbnail.widget)
                hosts[node.id] = controller.host
                thumbnail.setImage(session.thumbnails.images[node.id])
            }
            feed.show(hosts)
        }
        for (id, thumbnail) in thumbnails { thumbnail.setShowing(id == main?.id) }
        // The machine shown large: a new tile for each (its screen takes
        // its machine when it's made).
        if let main, let controller = session.controllers[main.id] {
            if mainTile?.id != main.id || mainTile?.controller !== controller {
                let tile = StationTileView(session: session, node: main, controller: controller, openStation: openStation)
                mainTile = tile
                self.main.child = NetworkAspectFrame(tile.widget, ratio: Renderer.aspect).margin(12)
                tile.setFocused(true, takeKeyboard: true)
            }
            if session.focused != main.id {
                // (After this change has settled.)
                MainLoop.after(0) { [session] in session.focus(main.id) }
            }
        } else {
            mainTile = nil
            self.main.child = nil
        }
    }

    private func show(_ id: UUID) {
        session.update { $0.workspace.focus = id }
        session.selection = [id]
        session.focus(id)
    }

    private func step(_ forward: Bool) {
        session.focusNext(forward)
        if let id = session.focused { show(id) }
    }
}

/// A machine in the Focus view's strip: its screen, live, and its name.
@MainActor
final class FocusThumbnail {
    let widget: Widget
    private let picture: StationScreenView
    private let name: String

    init(node: NetworkNode, _ action: @escaping @MainActor () -> Void) {
        name = node.name
        let picture = StationScreenView()
        self.picture = picture
        let width = Int32(NetworkFocusView.stripWidth - 20 - 12)
        let screen = Overlay(Bin().style("network-screen").size(width: width, height: Int32(Double(width) / Renderer.aspect))) {
            picture.area
        }
        gtk_widget_set_overflow(screen.widget, GTK_OVERFLOW_HIDDEN)
        let badge = StationNumberBadge(node.stationNumber)
        let label = Label(node.name, style: "caption-heading").ellipsize().maxWidthChars(1).expand(horizontal: true)
        let content = Box(.vertical, spacing: 5) {
            screen
            Box(.horizontal, spacing: 6) { badge; label }
        }
        let button = Button(child: content, action)
        button.style("flat", "network-thumbnail").tooltip("\(node.name): click to bring it here")
        widget = button
    }

    func setImage(_ image: PlatformImage?) {
        picture.image = image
    }

    func setShowing(_ showing: Bool) {
        widget.setStyle("showing", showing)
        widget.accessibleLabel("\(name)\(showing ? ", shown large" : "")")
    }
}
