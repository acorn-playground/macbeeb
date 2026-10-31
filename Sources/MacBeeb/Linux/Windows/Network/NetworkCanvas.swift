import BeebCore
import BeebHost
import BeebNetwork
import CGtk
import Foundation

/// The network laid out freely: machines as cards with their screens live,
/// the clock, and the bus they share drawn behind them. Pan by dragging the
/// background or scrolling, zoom with Control and the scroll wheel, a
/// pinch, or the zoom buttons. (The Mac's NetworkCanvas.)
@MainActor
final class NetworkCanvasView {
    let session: NetworkSession
    let root: Widget
    private let openStation: (UUID) -> Void
    private let openDebugger: (UUID) -> Void
    private let openHardware: (UUID) -> Void

    private let background: DrawingArea
    private let placed = PlacedChildren()
    private var machineCards: [UUID: MachineCard] = [:]
    private var clockCards: [UUID: ClockCard] = [:]
    private var remoteCards: [Int: RemoteStationCard] = [:]
    /// Where each card is in the view, for finding what's under the pointer.
    private var frames: [(id: UUID, x: Double, y: Double, width: Double, height: Double)] = []
    private var nodeOrder: [UUID] = []

    private(set) var zoom = 1.0
    private var centre = (x: 0.0, y: 0.0)
    private var size = (width: 0.0, height: 0.0)
    private var fitted = false
    /// Nodes being dragged, and how far (in view points).
    private var dragging: (ids: Set<UUID>, dx: Double, dy: Double)?
    private var panStart: (x: Double, y: Double)?
    private var pinchStart: Double?
    /// The press that might become a click: what it was on, and whether
    /// releasing it should make that the only thing selected.
    private var press: (node: UUID?, collapse: Bool)?
    private var moved = false
    private var animation: (from: (zoom: Double, x: Double, y: Double), to: (zoom: Double, x: Double, y: Double),
                            start: Int64?, duration: Double)?

    private let thumbnails: ThumbnailFeed
    private var mapped = false
    private let zoomLabel = Label("100%", style: "caption", "numeric")
    private let problems = Box(.vertical, spacing: 4)
    private let problemsCard: Widget
    private let paletteBox = Box(.vertical, spacing: 10)
    private let menu = Menu {}
    private let popover: Popover
    private let actions: NetworkActionGroup

    static let grid = 20.0
    static let zoomRange = 0.25...2.5
    /// Clear of the palette, on the left.
    static let paletteWidth = 200.0

    init(session: NetworkSession, openStation: @escaping (UUID) -> Void, openDebugger: @escaping (UUID) -> Void,
         openHardware: @escaping (UUID) -> Void) {
        self.session = session
        self.openStation = openStation
        self.openDebugger = openDebugger
        self.openHardware = openHardware
        thumbnails = ThumbnailFeed(session.thumbnails)
        background = DrawingArea { _, _, _ in }
        background.style("network-canvas").expand()

        // The cards, over the drawing (in a scroller that never scrolls, so
        // cards off the edge don't make the canvas want to be bigger).
        let scroller = ScrolledWindow(placed, horizontal: GTK_POLICY_EXTERNAL, vertical: GTK_POLICY_EXTERNAL)
        gtk_scrolled_window_set_kinetic_scrolling(cast(scroller.widget), 0)
        if let viewport = gtk_scrolled_window_get_child(cast(scroller.widget)) {
            gtk_viewport_set_scroll_to_focus(cast(viewport), 0)
        }
        for adjustment in [scroller.hadjustment, scroller.vadjustment] {
            GObjectRef(adjustment).on("value-changed") {
                if gtk_adjustment_get_value(cast(adjustment)) != 0 { gtk_adjustment_set_value(cast(adjustment), 0) }
            }
        }
        placed.focusable(true).accessibleLabel("Network canvas")
        popover = Popover(menu: menu)
        actions = NetworkActionGroup("canvas", on: placed)

        let (paletteBox, problems) = (self.paletteBox, self.problems)
        problemsCard = Bin(problems.margin(horizontal: 14, vertical: 8))
            .style("network-floating")
            .align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_START)
            .margin(top: 12)
        problemsCard.canTarget(false)
        let problemsCard = self.problemsCard
        let overlay = Overlay(background) {
            scroller
            paletteBox.align(horizontal: GTK_ALIGN_START, vertical: GTK_ALIGN_START).margin(12)
            problemsCard
        }
        root = overlay
        overlay.add(zoomControls().align(horizontal: GTK_ALIGN_END, vertical: GTK_ALIGN_END).margin(12))

        background.setDraw { [self] cairo, width, height in
            self.draw(cairo, width, height)
        }
        background.object.onSize("resize") { [self] width, height in
            self.resized(Double(width), Double(height))
        }
        buildPalette()
        installActions()
        installGestures()
        observe()
        root.onMap { [self] in
            self.mapped = true
            self.updateThumbnails()
        }
        root.onUnmap { [self] in
            self.mapped = false
            self.thumbnails.clear()
        }
        root.onDestroy { [self] in self.thumbnails.clear() }
        root.keep(self)

        zoom = session.project.canvas.zoom
        centre = (session.project.canvas.centre.x, session.project.canvas.centre.y)
        // A new network (zoom 0) starts with everything in view.
        fitted = zoom > 0
        if zoom <= 0 { zoom = 1 }
    }

    // MARK: State

    private func observe() {
        let session = session
        placed.track { [self] in
            let nodes = session.project.nodes
            _ = session.controllers
            _ = session.transmitting
            _ = session.paused
            _ = session.selection
            _ = session.status.stoppedStations
            for controller in session.controllers.values {
                _ = controller.consoleLine
                _ = controller.paused
                _ = controller.debugStop
            }
            _ = session.room
            self.sync(nodes)
        }
        placed.track { [self] in
            let images = session.thumbnails.images
            for (id, card) in self.machineCards {
                card.setImage(session.controllers[id] == nil ? nil : images[id])
            }
        }
        placed.track { [self] in
            let screens = session.remoteScreens
            for station in session.remoteStations {
                self.remoteCards[station.station]?.update(station, participant: session.participant(station.participantId),
                                                          screen: station.online ? screens[station.station] : nil)
            }
        }
        var shownProblems: [String]?
        problemsCard.track { [self] in
            let list = session.project.problems
            guard list.map(\.message) != shownProblems else { return }
            shownProblems = list.map(\.message)
            self.problems.removeAll()
            for problem in list {
                self.problems.append(Box(.horizontal, spacing: 8) {
                    Icon("dialog-warning-symbolic", size: 16).style("warning")
                    Label(problem.message).wrap()
                })
            }
            self.problemsCard.isVisible = !list.isEmpty
        }
    }

    /// Cards for the nodes, made and dropped as they come and go, and
    /// brought up to date.
    private func sync(_ nodes: [NetworkNode]) {
        let ids = Set(nodes.map(\.id))
        for (id, card) in machineCards where !ids.contains(id) || session.node(id)?.kind == .clock {
            placed.remove(card.widget)
            machineCards[id] = nil
        }
        for (id, card) in clockCards where !ids.contains(id) || session.node(id)?.kind != .clock {
            placed.remove(card.widget)
            clockCards[id] = nil
        }
        let problems = session.project.problems
        for node in nodes {
            let selected = session.selection.contains(node.id)
            if node.kind == .clock {
                let card = clockCards[node.id] ?? makeClockCard(node)
                card.update(node, selected: selected)
            } else {
                let card = machineCards[node.id] ?? makeMachineCard(node)
                card.update(node, session: session, selected: selected,
                            problem: problems.first { $0.nodes.contains(node.id) }?.message)
            }
        }
        nodeOrder = nodes.map(\.id)
        // The room's other machines.
        let remote = session.remoteStations
        let stations = Set(remote.map(\.station))
        for (station, card) in remoteCards where !stations.contains(station) {
            placed.remove(card.widget)
            remoteCards[station] = nil
        }
        for station in remote where remoteCards[station.station] == nil {
            let card = RemoteStationCard(station: station)
            placed.put(card.widget)
            remoteCards[station.station] = card
            card.update(station, participant: session.participant(station.participantId),
                        screen: station.online ? session.remoteScreens[station.station] : nil)
        }
        updateThumbnails()
        layout()
    }

    private func makeMachineCard(_ node: NetworkNode) -> MachineCard {
        let card = MachineCard(node: node)
        placed.put(card.widget)
        machineCards[node.id] = card
        watchFocus(card.widget, node.id)
        return card
    }

    private func makeClockCard(_ node: NetworkNode) -> ClockCard {
        let card = ClockCard(node: node)
        placed.put(card.widget)
        clockCards[node.id] = card
        watchFocus(card.widget, node.id)
        return card
    }

    /// Tabbing to a card selects it (as a click does).
    private func watchFocus(_ widget: Widget, _ id: UUID) {
        let focus = FocusController()
        focus.onEnter { [self] in
            if !self.session.selection.contains(id) {
                self.session.selection = [id]
            }
        }
        widget.add(focus)
    }

    private func updateThumbnails() {
        guard mapped else { return }
        var wanted: [UUID: EmulatorHost] = [:]
        for id in machineCards.keys {
            if let controller = session.controllers[id] { wanted[id] = controller.host }
        }
        thumbnails.show(wanted)
    }

    // MARK: Geometry

    private func resized(_ width: Double, _ height: Double) {
        size = (width, height)
        if !fitted, width > 0, height > 0 {
            fitted = true
            fit(animated: false)
        }
        layout()
    }

    /// Where a node is, in canvas points, allowing for a drag.
    private func position(of node: NetworkNode) -> (x: Double, y: Double) {
        var point = (x: node.position.x, y: node.position.y)
        if let dragging, dragging.ids.contains(node.id) {
            point.x += dragging.dx / zoom
            point.y += dragging.dy / zoom
        }
        return point
    }

    private func viewPoint(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        ((x - centre.x) * zoom + size.width / 2, (y - centre.y) * zoom + size.height / 2)
    }

    private func canvasPoint(_ x: Double, _ y: Double) -> CanvasPoint {
        CanvasPoint(x: (x - size.width / 2) / zoom + centre.x, y: (y - size.height / 2) / zoom + centre.y)
    }

    private func snapped(_ point: CanvasPoint) -> CanvasPoint {
        guard session.project.canvas.snapToGrid else { return point }
        return CanvasPoint(x: (point.x / Self.grid).rounded() * Self.grid, y: (point.y / Self.grid).rounded() * Self.grid)
    }

    /// Where the room's other machines go: along the end of the stations'
    /// row, after everything of this network's.
    private var remoteLayout: [(station: StationView, x: Double, y: Double)] {
        let remote = session.remoteStations
        guard !remote.isEmpty else { return [] }
        let stations = session.project.nodes.filter { $0.kind == .station }
        let y = stations.isEmpty ? 0 : stations.map(\.position.y).sorted()[stations.count / 2]
        let x = (session.project.nodes.map(\.position.x).max() ?? -NetworkProject.columnSpacing) + NetworkProject.columnSpacing
        return remote.enumerated().map { index, station in
            (station, x + Double(index) * NetworkProject.columnSpacing, y)
        }
    }

    /// Puts every card where it belongs, at the zoom, and redraws the bus.
    private func layout() {
        guard size.width > 0 else { return }
        var frames: [(id: UUID, x: Double, y: Double, width: Double, height: Double)] = []
        for id in nodeOrder {
            guard let node = session.node(id) else { continue }
            let widget: Widget? = machineCards[id]?.widget ?? clockCards[id]?.widget
            guard let widget else { continue }
            let (width, height) = networkNaturalSize(of: widget)
            let point = position(of: node)
            let view = viewPoint(point.x, point.y)
            let x = view.x - width * zoom / 2, y = view.y - height * zoom / 2
            placed.place(widget, x: x, y: y, scale: zoom)
            frames.append((id, x, y, width * zoom, height * zoom))
        }
        for item in remoteLayout {
            guard let card = remoteCards[item.station.station] else { continue }
            let (width, height) = networkNaturalSize(of: card.widget)
            let view = viewPoint(item.x, item.y)
            placed.place(card.widget, x: view.x - width * zoom / 2, y: view.y - height * zoom / 2, scale: zoom)
        }
        self.frames = frames
        zoomLabel.text = "\(Int((zoom * 100).rounded()))%"
        background.queueDraw()
    }

    /// The node under a point in the view, the one on top first.
    private func node(at x: Double, _ y: Double) -> UUID? {
        frames.last { x >= $0.x && x < $0.x + $0.width && y >= $0.y && y < $0.y + $0.height }?.id
    }

    // MARK: Drawing

    private func draw(_ cairo: Cairo, _ width: Double, _ height: Double) {
        // A faint dot grid that moves and scales with the canvas.
        let step = Self.grid * 2 * zoom
        if step >= 6 {
            let origin = viewPoint(0, 0)
            let startX = origin.x.truncatingRemainder(dividingBy: step) - step
            let startY = origin.y.truncatingRemainder(dividingBy: step) - step
            let dot = max(1, 1.4 * zoom) / 2
            cairo.foreground(of: background, alpha: 0.22)
            var y = startY
            while y < height + step {
                var x = startX
                while x < width + step {
                    cairo.circle(x, y, radius: dot)
                    x += step
                }
                y += step
            }
            cairo.fill()
        }
        drawBus(cairo)
    }

    /// The shared bus: a backbone between the rows of machines, and a drop
    /// from each to it. It's a picture of a shared medium, not of the
    /// cabling.
    private func drawBus(_ cairo: Cairo) {
        let nodes = session.project.nodes
        let remote = remoteLayout.map { (point: viewPoint($0.x, $0.y), online: $0.station.online) }
        guard nodes.count + remote.count > 1 else { return }
        let points = nodes.map { node -> (node: NetworkNode, point: (x: Double, y: Double)) in
            let p = position(of: node)
            return (node, viewPoint(p.x, p.y))
        }
        let ys = points.map(\.point.y)
        let busY = ys.isEmpty ? remote[0].point.y : (ys.min()! + ys.max()!) / 2
        let xs = points.map(\.point.x) + remote.map(\.point.x)
        let lineWidth = max(1.5, 3 * zoom)
        cairo_set_line_cap(cairo.context, CAIRO_LINE_CAP_ROUND)
        cairo.foreground(of: background, alpha: 0.4)
        cairo.move(xs.min()!, busY)
        cairo.line(xs.max()!, busY)
        cairo.stroke(width: lineWidth)
        let lit = Set(session.controllers.keys)
        for (node, point) in points {
            let on = lit.contains(node.id) || node.kind == .clock
            let sending = session.transmitting.contains(node.id)
            if sending {
                cairo.color(hex: NetworkStyles.green, alpha: 0.35)
                cairo.move(point.x, point.y)
                cairo.line(point.x, busY)
                cairo.stroke(width: lineWidth * 3)
            }
            if sending {
                cairo.color(hex: NetworkStyles.green)
            } else if on {
                cairo.accent(alpha: 0.6)
            } else {
                cairo.foreground(of: background, alpha: 0.3)
            }
            if !on { cairo.dash([4 * zoom, 4 * zoom]) }
            cairo.move(point.x, point.y)
            cairo.line(point.x, busY)
            cairo.stroke(width: lineWidth * 0.8)
            cairo.dash([])
            if on { cairo.accent() } else { cairo.foreground(of: background, alpha: 0.45) }
            cairo.circle(point.x, busY, radius: lineWidth * 1.5)
            cairo.fill()
        }
        // Remote machines: through the Internet gateway, drawn apart.
        for (point, online) in remote {
            if online { cairo.color(hex: NetworkStyles.teal, alpha: 0.75) } else { cairo.foreground(of: background, alpha: 0.3) }
            cairo.dash([6 * zoom, 3 * zoom])
            cairo.move(point.x, point.y)
            cairo.line(point.x, busY)
            cairo.stroke(width: lineWidth * 0.8)
            cairo.dash([])
            if online { cairo.color(hex: NetworkStyles.teal) } else { cairo.foreground(of: background, alpha: 0.45) }
            cairo.circle(point.x, busY, radius: lineWidth * 1.5)
            cairo.fill()
        }
    }

    // MARK: The pointer

    private func installGestures() {
        let click = ClickGesture(button: 1)
        click.onPressed { [self, click] count, x, y in
            self.pressed(count, x, y, click.modifiers)
        }
        click.onReleased { [self] _, _, _ in self.released() }
        placed.add(click)

        let drag = DragGesture(button: 1)
        drag.onBegin { [self] x, y in
            self.moved = false
            self.dragStart = (x, y, self.node(at: x, y))
        }
        drag.onUpdate { [self, drag] dx, dy in
            self.dragged(dx, dy, gesture: drag)
        }
        drag.onEnd { [self] _, _ in self.dragEnded() }
        placed.add(drag)

        placed.onContextClick { [self] x, y in self.contextMenu(at: x, y) }

        let scroll = ScrollController()
        scroll.onScroll { [self, scroll] dx, dy in
            let unit = gtk_event_controller_scroll_get_unit(cast(scroll.controller))
            // Wheels scroll in notches; touchpads in pixels.
            let scale = unit == GDK_SCROLL_UNIT_WHEEL ? 40.0 : 1.0
            if scroll.modifiers.control {
                let (x, y) = self.pointer ?? (self.size.width / 2, self.size.height / 2)
                self.zoom(by: unit == GDK_SCROLL_UNIT_WHEEL ? pow(1.1, -dy) : 1 - dy / 200, at: x, y)
            } else {
                self.stopAnimation()
                self.centre.x += dx * scale / self.zoom
                self.centre.y += dy * scale / self.zoom
                self.layout()
                self.rememberView()
            }
            return true
        }
        placed.add(scroll)

        let motion = MotionController()
        motion.onMotion { [self] x, y in self.pointer = (x, y) }
        motion.onLeave { [self] in self.pointer = nil }
        placed.add(motion)

        networkOnPinch(placed, begin: { [self] in self.pinchStart = self.zoom }, changed: { [self] scale in
            guard let start = self.pinchStart else { return }
            let (x, y) = self.pointer ?? (self.size.width / 2, self.size.height / 2)
            self.zoom(by: (start * scale).within(Self.zoomRange) / self.zoom, at: x, y)
        }, end: { [self] in self.pinchStart = nil })

        // Palette items, and saved machines, dropped where they're wanted.
        networkStringDrop(to: placed) { [self] value, x, y in
            // Where it's dropped, unless that's on another card.
            let point = self.session.project.freePosition(near: self.snapped(self.canvasPoint(x, y)))
            if let id = Self.savedMachineID(fromDrag: value), let saved = MachineConfigurations.shared[id] {
                self.add(saved, at: point)
                return true
            }
            guard let item = PaletteItem(rawValue: value) else { return false }
            self.add(item, at: point)
            return true
        }
        // Files onto the file server go on its disc.
        placed.onDropFiles { [self] urls, x, y in
            guard let id = self.node(at: x, y), self.session.node(id)?.kind == .fileServer else { return false }
            self.session.addFilesToServer(id, urls)
            return true
        }

        networkOnKey(placed) { [self] keyval, state in self.key(keyval, state) }
    }

    private var pointer: (x: Double, y: Double)?
    private var dragStart: (x: Double, y: Double, node: UUID?)?

    private func pressed(_ count: Int32, _ x: Double, _ y: Double, _ modifiers: GdkModifierType) {
        let hit = node(at: x, y)
        if count >= 2 {
            press = nil
            // Double-click: a machine's window, switched on if it's off.
            if let hit, session.node(hit)?.isMachine == true {
                if !session.isOn(hit) { session.powerOn(hit) }
                openStation(hit)
            }
            return
        }
        guard let hit else {
            press = (nil, false)
            placed.grabFocus()
            return
        }
        if modifiers.control || modifiers.shift {
            toggleSelection(hit)
            press = nil
            placed.grabFocus()
            return
        }
        if session.selection.contains(hit) {
            press = (hit, session.selection.count > 1)
        } else {
            session.selection = [hit]
            press = (hit, false)
        }
        if session.node(hit)?.isMachine == true, session.isOn(hit) { session.focus(hit) }
        (machineCards[hit]?.widget ?? clockCards[hit]?.widget)?.grabFocus()
    }

    private func released() {
        defer { press = nil }
        guard let press, !moved else { return }
        if let node = press.node {
            if press.collapse { session.selection = [node] }
        } else {
            session.selection = []
        }
    }

    private func dragged(_ dx: Double, _ dy: Double, gesture: DragGesture) {
        guard let start = dragStart else { return }
        if !moved {
            guard abs(dx) > 3 || abs(dy) > 3 else { return }
            moved = true
            gtk_gesture_set_state(cast(gesture.controller), GTK_EVENT_SEQUENCE_CLAIMED)
            stopAnimation()
            if let node = start.node {
                if !session.selection.contains(node) { session.selection = [node] }
                dragging = (session.selection, 0, 0)
                placed.cursor("grabbing")
            } else {
                panStart = centre
                placed.cursor("grabbing")
            }
        }
        if dragging != nil {
            dragging?.dx = dx
            dragging?.dy = dy
        } else if let panStart {
            centre = (panStart.x - dx / zoom, panStart.y - dy / zoom)
        }
        layout()
    }

    private func dragEnded() {
        placed.cursor(nil)
        dragStart = nil
        if let dragging {
            self.dragging = nil
            for id in dragging.ids {
                guard let node = session.node(id) else { continue }
                let x = node.position.x + dragging.dx / zoom, y = node.position.y + dragging.dy / zoom
                session.move(id, to: snapped(CanvasPoint(x: x, y: y)))
            }
            layout()
        } else if panStart != nil {
            panStart = nil
            rememberView()
        }
    }

    private func toggleSelection(_ id: UUID) {
        if session.selection.contains(id) {
            session.selection.remove(id)
        } else {
            session.selection.insert(id)
        }
    }

    // MARK: The keyboard

    private func key(_ keyval: UInt32, _ state: GdkModifierType) -> Bool {
        let selection = session.selection
        switch Int32(keyval) {
        case GDK_KEY_Delete, GDK_KEY_BackSpace, GDK_KEY_KP_Delete:
            guard !selection.isEmpty else { return false }
            confirmRemoval(selection)
            return true
        case GDK_KEY_Return, GDK_KEY_KP_Enter, GDK_KEY_space:
            guard selection.count == 1, let id = selection.first, session.node(id)?.isMachine == true else { return false }
            if !session.isOn(id) { session.powerOn(id) }
            openStation(id)
            return true
        case GDK_KEY_Escape:
            guard !selection.isEmpty else { return false }
            session.selection = []
            placed.grabFocus()
            return true
        case GDK_KEY_a where state.control:
            session.selection = Set(session.project.nodes.map(\.id))
            return true
        case GDK_KEY_Menu, GDK_KEY_F10:
            guard keyval == UInt32(GDK_KEY_Menu) || state.shift, let id = selection.first, let frame = frames.first(where: { $0.id == id }) else { return false }
            contextMenu(at: frame.x + frame.width / 2, frame.y + frame.height / 2)
            return true
        case GDK_KEY_Left, GDK_KEY_Right, GDK_KEY_Up, GDK_KEY_Down:
            // Alt and an arrow moves what's selected, a grid step at a time.
            guard state.alt, !selection.isEmpty else { return false }
            let step = state.shift ? Self.grid * 5 : Self.grid
            let (dx, dy): (Double, Double) = switch Int32(keyval) {
            case GDK_KEY_Left: (-step, 0)
            case GDK_KEY_Right: (step, 0)
            case GDK_KEY_Up: (0, -step)
            default: (0, step)
            }
            for id in selection {
                guard let node = session.node(id) else { continue }
                session.move(id, to: snapped(CanvasPoint(x: node.position.x + dx, y: node.position.y + dy)))
            }
            return true
        case GDK_KEY_plus, GDK_KEY_equal, GDK_KEY_KP_Add:
            guard !state.alt else { return false }
            setZoom(zoom * 1.25)
            return true
        case GDK_KEY_minus, GDK_KEY_KP_Subtract:
            guard !state.alt else { return false }
            setZoom(zoom / 1.25)
            return true
        default:
            return false
        }
    }

    // MARK: The context menu

    private func installActions() {
        let session = session
        func ids(_ value: String) -> UUID? { UUID(uuidString: value) }
        actions.add("power") { value in if let id = ids(value) { session.togglePower(id) } }
        actions.add("cold-boot") { value in if let id = ids(value) { session.coldBoot(id) } }
        actions.add("break") { value in if let id = ids(value) { session.pressBreak(id) } }
        actions.add("suspend") { value in
            if let id = ids(value) { session.setSuspended(id, !session.isSuspended(id)) }
        }
        actions.add("open-window") { [self] value in
            guard let id = ids(value) else { return }
            if !session.isOn(id) { session.powerOn(id) }
            self.openStation(id)
        }
        actions.add("debugger") { [self] value in if let id = ids(value) { self.openDebugger(id) } }
        actions.add("hardware") { [self] value in if let id = ids(value) { self.openHardware(id) } }
        actions.add("insert-disc") { value in if let id = ids(value) { session.chooseDisc(for: id, drive: 0) } }
        actions.add("eject") { value in if let id = ids(value) { session.eject(id, drive: 0) } }
        actions.add("start-file-server") { value in if let id = ids(value) { session.startFileServer(id) } }
        actions.add("add-files") { value in if let id = ids(value) { session.chooseFilesForServer(id) } }
        actions.add("start-printer-server") { value in if let id = ids(value) { session.startPrinterServer(id) } }
        actions.add(plain: "print-centre") { PrintCentreWindow.show() }
        actions.add("duplicate") { value in if let id = ids(value) { session.duplicate(id) } }
        actions.add("remove") { [self] value in
            guard let id = ids(value) else { return }
            self.confirmRemoval(session.selection.contains(id) ? session.selection : [id])
        }
    }

    private func contextMenu(at x: Double, _ y: Double) {
        guard let id = node(at: x, y), let node = session.node(id) else { return }
        if !session.selection.contains(id) { session.selection = [id] }
        let target = id.uuidString
        let on = session.isOn(id)
        var entries: [MenuEntry] = []
        if node.isMachine {
            entries.append(MenuSection {
                MenuItem(on ? "Power Off" : "Power On", "canvas.power", target: target)
                MenuItem("Cold Boot", "canvas.cold-boot", target: target)
                MenuItem("Break", "canvas.break", target: target)
                MenuItem(session.isSuspended(id) ? "Resume Station" : "Suspend Station", "canvas.suspend", target: target)
            })
            entries.append(MenuSection {
                MenuItem("Open Window", "canvas.open-window", target: target)
                MenuItem("Show Debugger", "canvas.debugger", target: target)
                MenuItem("Hardware…", "canvas.hardware", target: target)
                MenuItem("Insert Disc in Drive 0…", "canvas.insert-disc", target: target)
                MenuItem("Eject Drive 0", "canvas.eject", target: target)
            })
            if node.kind == .fileServer {
                entries.append(MenuSection {
                    MenuItem("Start File Server", "canvas.start-file-server", target: target)
                    MenuItem("Add Files…", "canvas.add-files", target: target)
                })
            }
            if node.kind == .printServer {
                entries.append(MenuSection {
                    MenuItem("Start Printer Server", "canvas.start-printer-server", target: target)
                    MenuItem("Print Centre", "canvas.print-centre")
                })
            }
            entries.append(MenuSection { MenuItem("Duplicate", "canvas.duplicate", target: target) })
        }
        entries.append(MenuSection { MenuItem("Remove…", "canvas.remove", target: target) })
        actions.setEnabled("break", on)
        actions.setEnabled("suspend", on)
        actions.setEnabled("debugger", on)
        actions.setEnabled("eject", node.discs[0] != nil)
        menu.set(entries)
        popover.show(on: placed, at: x, y: y)
    }

    /// (For the preview: the selection's context menu, and a picture of it.)
    func showMenuForSelection(capturingTo path: String) {
        guard let id = session.selection.first, let frame = frames.first(where: { $0.id == id }) else { return }
        contextMenu(at: frame.x + frame.width / 2, frame.y + frame.height / 2)
        MainLoop.after(1) { [self] in Capture.write(self.popover, to: path) }
    }

    private func confirmRemoval(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let title: String
        if ids.count == 1, let node = session.node(ids.first!) {
            title = "Remove “\(node.name)” from the network?"
        } else {
            title = "Remove \(ids.count) items from the network?"
        }
        let session = session
        AlertDialog(title, body: "Machines that are on are switched off, and their discs’ copies in the network are deleted.")
            .response("cancel", "_Cancel")
            .response("remove", "_Remove", .destructive)
            .defaults(default: "cancel", close: "cancel")
            .choose(over: root) { response in
                if response == "remove" { session.remove(ids) }
            }
    }

    // MARK: The palette

    enum PaletteItem: String, CaseIterable {
        case modelB, master128, elitePlayer, fileServer, level2FileServer, printServer, clock

        var title: String {
            switch self {
            case .modelB: "BBC Model B"
            case .master128: "Master 128"
            case .elitePlayer: "Elite Player"
            case .fileServer: "File Server"
            case .level2FileServer: "Level 2 File Server"
            case .printServer: "Printer Server"
            case .clock: "Clock"
            }
        }

        var kind: NetworkNode.Kind {
            switch self {
            case .modelB, .master128, .elitePlayer: .station
            case .fileServer, .level2FileServer: .fileServer
            case .printServer: .printServer
            case .clock: .clock
            }
        }

        var icon: String {
            switch self {
            case .modelB: "computer-symbolic"
            case .master128: "video-display-symbolic"
            case .elitePlayer: "airplane-mode-symbolic"
            case .fileServer: "network-server-symbolic"
            case .level2FileServer: "drive-multidisk-symbolic"
            case .printServer: "printer-network-symbolic"
            case .clock: "preferences-system-time-symbolic"
            }
        }
    }

    /// "saved:UUID", a saved machine dragged from the palette.
    static func savedMachineID(fromDrag item: String) -> UUID? {
        item.hasPrefix("saved:") ? UUID(uuidString: String(item.dropFirst(6))) : nil
    }

    private func paletteButton(_ title: String, icon: String, tooltip: String, drag: String,
                               _ action: @escaping @MainActor () -> Void) -> Button {
        let content = Box(.horizontal, spacing: 8) {
            Icon(icon, size: 16).size(width: 24)
            Label(title).ellipsize().maxWidthChars(18)
        }
        let button = Button(child: content, action)
        button.style("flat", "network-palette-item").tooltip(tooltip)
        networkStringDrag(to: button, drag)
        return button
    }

    private func buildPalette() {
        let session = session
        let palette = Box(.vertical, spacing: 1)
        palette.append(Label("Add", style: "network-palette-title", "dim-label"))
        var clockButton: Button?
        for item in PaletteItem.allCases {
            let button = paletteButton(item.title, icon: item.icon, tooltip: "Drag onto the network, or click to add",
                                       drag: item.rawValue) { [self] in
                // At the end of its row, along the trunk.
                self.add(item, at: session.project.nextPosition(for: item.kind))
            }
            if item == .clock { clockButton = button }
            palette.append(button)
        }
        let card = Bin(palette.margin(6)).style("network-floating").size(width: 180)
        paletteBox.append(card)
        if let clockButton {
            clockButton.track { [clockButton] in
                let has = session.project.hasClock
                clockButton.isEnabled = !has
                clockButton.tooltip(has ? "The network has its clock" : "Drag onto the network, or click to add")
            }
        }
        // The user's saved machine configurations, under the palette.
        let saved = Box(.vertical, spacing: 1)
        let savedCard = Bin(saved.margin(6)).style("network-floating").size(width: 180)
        paletteBox.append(savedCard)
        savedCard.track { [self, saved, savedCard] in
            let machines = MachineConfigurations.shared.machines
            saved.removeAll()
            savedCard.isVisible = !machines.isEmpty
            guard !machines.isEmpty else { return }
            saved.append(Label("My Machines", style: "network-palette-title", "dim-label"))
            for machine in machines {
                let summary = [machine.setup.model.displayName, machine.setup.fittedSummary].filter { !$0.isEmpty }.joined(separator: " · ")
                saved.append(self.paletteButton(machine.name, icon: machine.setup.model.isMaster ? "video-display-symbolic" : "computer-symbolic",
                                                tooltip: summary + ". Drag onto the network, or click to add",
                                                drag: "saved:\(machine.id.uuidString)") { [self] in
                    self.add(machine, at: session.project.nextPosition(for: .station))
                })
            }
        }
    }

    /// (For the preview: a palette item clicked.)
    func addFromPalette(_ value: String) {
        guard let item = PaletteItem(rawValue: value) else { return }
        add(item, at: session.project.nextPosition(for: item.kind))
    }

    private func add(_ saved: SavedMachine, at point: CanvasPoint) {
        if let id = session.add(saved, at: point) {
            session.selection = [id]
            reveal(point)
        }
    }

    private func add(_ item: PaletteItem, at point: CanvasPoint) {
        let id: UUID? = switch item {
        case .modelB: session.add(.station, model: .modelB, at: point)
        case .master128: session.add(.station, model: .master128, at: point)
        case .elitePlayer: session.addElitePlayer(at: point)
        case .fileServer: session.add(.fileServer, at: point)
        case .level2FileServer: session.add(.fileServer, level: .level2, at: point)
        case .printServer: session.add(.printServer, at: point)
        case .clock: session.add(.clock, at: point)
        }
        if let id {
            session.selection = [id]
            reveal(point)
        }
    }

    /// Pans to show `point` (a new card) if it's off the canvas.
    private func reveal(_ point: CanvasPoint) {
        let view = viewPoint(point.x, point.y)
        let margin = 140 * zoom
        guard view.x < margin + 180 || view.x > size.width - margin || view.y < margin || view.y > size.height - margin else { return }
        animate(to: (zoom, point.x, (centre.y + point.y) / 2), duration: 0.3)
    }

    // MARK: Zoom

    private func zoomControls() -> Widget {
        let out = Button(icon: "zoom-out-symbolic") { [self] in self.setZoom(self.zoom / 1.25) }
            .style("flat", "circular").tooltip("Zoom out").accessibleLabel("Zoom out")
        let `in` = Button(icon: "zoom-in-symbolic") { [self] in self.setZoom(self.zoom * 1.25) }
            .style("flat", "circular").tooltip("Zoom in").accessibleLabel("Zoom in")
        let fit = Button(icon: "zoom-fit-best-symbolic") { [self] in self.fit() }
            .style("flat", "circular").tooltip("Show the whole network").accessibleLabel("Show the whole network")
        zoomLabel.widthChars(5).centred()
        return Box(.horizontal, spacing: 2) {
            out
            zoomLabel
            `in`
            Separator(GTK_ORIENTATION_VERTICAL).margin(horizontal: 4, vertical: 6)
            fit
        }
        .style("network-floating", "pill")
    }

    func setZoom(_ value: Double, animated: Bool = true) {
        let target = value.within(Self.zoomRange)
        if animated {
            animate(to: (target, centre.x, centre.y), duration: 0.15)
        } else {
            zoom = target
            layout()
            rememberView()
        }
    }

    /// Zooms by `factor`, keeping the point under (x, y) where it is.
    private func zoom(by factor: Double, at x: Double, _ y: Double) {
        stopAnimation()
        let before = canvasPoint(x, y)
        zoom = (zoom * factor).within(Self.zoomRange)
        let after = canvasPoint(x, y)
        centre.x += before.x - after.x
        centre.y += before.y - after.y
        layout()
        rememberView()
    }

    /// Zooms and centres to show every node, and the room's other machines.
    func fit(animated: Bool = true) {
        let points = session.project.nodes.map { ($0.position.x, $0.position.y) } + remoteLayout.map { ($0.x, $0.y) }
        guard !points.isEmpty, size.width > 0 else { return }
        let xs = points.map(\.0), ys = points.map(\.1)
        let width = (xs.max()! - xs.min()!) + MachineCard.width + 80
        let height = (ys.max()! - ys.min()!) + MachineCard.height + 80
        let palette = Self.paletteWidth
        let fitted = min((size.width - palette) / width, size.height / height, 1.5).within(Self.zoomRange)
        let target = (fitted, (xs.max()! + xs.min()!) / 2 - palette / 2 / fitted, (ys.max()! + ys.min()!) / 2)
        if animated {
            animate(to: target, duration: 0.25)
        } else {
            zoom = target.0
            centre = (target.1, target.2)
            layout()
            rememberView()
        }
    }

    private func animate(to target: (zoom: Double, x: Double, y: Double), duration: Double) {
        let running = animation != nil
        animation = ((zoom, centre.x, centre.y), target, nil, duration)
        guard !running else { return }
        placed.onTick { [self] time in
            guard var animation = self.animation else { return false }
            if animation.start == nil {
                animation.start = time
                self.animation = animation
            }
            let t = min(1, Double(time - animation.start!) / 1_000_000 / animation.duration)
            // Ease in and out.
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let from = animation.from, to = animation.to
            self.zoom = from.zoom + (to.zoom - from.zoom) * e
            self.centre = (from.x + (to.x - from.x) * e, from.y + (to.y - from.y) * e)
            self.layout()
            if t >= 1 {
                self.animation = nil
                self.rememberView()
                return false
            }
            return true
        }
    }

    private func stopAnimation() {
        animation = nil
    }

    private var rememberToken = 0

    /// Saves where the canvas was looking, once it's still.
    private func rememberView() {
        rememberToken += 1
        let token = rememberToken
        MainLoop.after(0.4) { [self] in
            guard token == self.rememberToken else { return }
            let zoom = self.zoom, centre = self.centre
            self.session.update {
                $0.canvas.zoom = zoom
                $0.canvas.centre = CanvasPoint(x: centre.x, y: centre.y)
            }
        }
    }
}

fileprivate extension GdkModifierType {
    var control: Bool { rawValue & GDK_CONTROL_MASK.rawValue != 0 }
    var shift: Bool { rawValue & GDK_SHIFT_MASK.rawValue != 0 }
    var alt: Bool { rawValue & GDK_ALT_MASK.rawValue != 0 }
}

fileprivate extension Double {
    func within(_ range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
