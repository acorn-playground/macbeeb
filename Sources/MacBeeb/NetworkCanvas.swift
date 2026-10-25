import AppKit
import BeebCore
import BeebHost
import BeebNetwork
import SwiftUI

/// The network laid out freely: machines as cards with their screens live,
/// the clock, and the bus they share drawn behind them. Pan by dragging the
/// background or scrolling, zoom by pinching or ⌘-scrolling.
struct NetworkCanvas: View {
    @Bindable var session: NetworkSession
    /// Asks the studio to open a station's window.
    var openStation: (UUID) -> Void
    var openDebugger: (UUID) -> Void
    var openHardware: (UUID) -> Void

    @State private var zoom = 1.0
    @State private var centre = CGPoint.zero
    @State private var panStart: CGPoint?
    @State private var zoomStart: Double?
    /// Nodes being dragged, and how far (in view points).
    @State private var dragging: (ids: Set<UUID>, translation: CGSize)?
    @State private var removing: Set<UUID>?
    @State private var size = CGSize(width: 800, height: 600)
    @AccessibilityFocusState private var focusedNode: UUID?

    static let grid = 20.0
    static let zoomRange = 0.25...2.5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                background
                let remote = remoteLayout
                BusDrawing(nodes: session.project.nodes, position: { viewPoint(position(of: $0)) }, zoom: zoom,
                           lit: Set(session.controllers.keys), transmitting: session.transmitting,
                           remote: remote.map { (viewPoint($0.point), $0.station.online) })
                    .allowsHitTesting(false)
                ForEach(session.project.nodes) { node in
                    nodeView(node)
                        .scaleEffect(zoom)
                        .position(viewPoint(position(of: node)))
                }
                ForEach(remote, id: \.station.station) { item in
                    RemoteStationCard(station: item.station, participant: session.participant(item.station.participantId),
                                      screen: item.station.online ? session.remoteScreens[item.station.station] : nil)
                        .scaleEffect(zoom)
                        .position(viewPoint(item.point))
                }
                VStack(alignment: .leading, spacing: 10) {
                    palette
                    savedMachinesPalette
                }
                .padding(12)
                if !session.project.problems.isEmpty {
                    problems
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, 12)
                }
                zoomControls
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(12)
            }
            .coordinateSpace(.named("canvas"))
            .clipped()
            .onAppear {
                size = geometry.size
                zoom = session.project.canvas.zoom
                centre = CGPoint(x: session.project.canvas.centre.x, y: session.project.canvas.centre.y)
                // A new network (zoom 0) starts with everything in view.
                if zoom <= 0 {
                    zoom = 1
                    DispatchQueue.main.async { fit(animated: false) }
                }
            }
            .onChange(of: geometry.size) { size = geometry.size }
            .background(ScrollCatcher { delta, zooming, location in
                scrolled(delta, zooming: zooming, at: location)
            })
            .gesture(MagnifyGesture()
                .onChanged { value in
                    if zoomStart == nil { zoomStart = zoom }
                    zoom = (zoomStart! * value.magnification).clamped(to: Self.zoomRange)
                }
                .onEnded { _ in
                    zoomStart = nil
                    rememberView()
                })
            .dropDestination(for: String.self) { items, location in
                // Where it's dropped, unless that's on another card.
                let point = session.project.freePosition(near: snapped(canvasPoint(location)))
                if let id = items.first.flatMap(Self.savedMachineID(fromDrag:)), let saved = MachineConfigurations.shared[id] {
                    add(saved, at: point)
                    return true
                }
                guard let item = items.first.flatMap(PaletteItem.init(rawValue:)) else { return false }
                add(item, at: point)
                return true
            }
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let removing { session.remove(removing) }
                removing = nil
            }
        } message: {
            Text("Machines that are on are switched off, and their discs’ copies in the network are deleted.")
        }
        .onDeleteCommand {
            if !session.selection.isEmpty { removing = session.selection }
        }
        .focusable()
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Network canvas")
    }

    // MARK: Background

    private var background: some View {
        Canvas { context, size in
            // A faint dot grid that moves and scales with the canvas.
            let step = Self.grid * 2 * zoom
            guard step >= 6 else { return }
            let origin = viewPoint(.zero)
            let startX = origin.x.truncatingRemainder(dividingBy: step) - step
            let startY = origin.y.truncatingRemainder(dividingBy: step) - step
            let dot = max(1, 1.4 * zoom)
            var path = Path()
            var y = startY
            while y < size.height + step {
                var x = startX
                while x < size.width + step {
                    path.addEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                    x += step
                }
                y += step
            }
            context.fill(path, with: .color(.secondary.opacity(0.25)))
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                if panStart == nil { panStart = centre }
                centre = CGPoint(x: panStart!.x - value.translation.width / zoom, y: panStart!.y - value.translation.height / zoom)
            }
            .onEnded { _ in
                panStart = nil
                rememberView()
            })
        .onTapGesture {
            session.selection = []
        }
        .accessibilityHidden(true)
    }

    // MARK: Nodes

    @ViewBuilder
    private func nodeView(_ node: NetworkNode) -> some View {
        let selected = session.selection.contains(node.id)
        let problem = session.project.problems.first { $0.nodes.contains(node.id) }
        Group {
            if node.kind == .clock {
                ClockCard(node: node, selected: selected)
            } else {
                MachineCard(session: session, node: node, selected: selected, problem: problem?.message)
                    .dropDestination(for: URL.self) { urls, _ in
                        // Mac files onto the file server go on its disc.
                        guard node.kind == .fileServer, !urls.isEmpty else { return false }
                        session.addFilesToServer(node.id, urls)
                        return true
                    }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(count: 2) {
            if node.isMachine {
                if !session.isOn(node.id) { session.powerOn(node.id) }
                openStation(node.id)
            }
        }
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { toggleSelection(node.id) })
        .simultaneousGesture(TapGesture().modifiers(.shift).onEnded { toggleSelection(node.id) })
        .onTapGesture {
            if !NSEvent.modifierFlags.contains(.command) && !NSEvent.modifierFlags.contains(.shift) {
                session.selection = [node.id]
                if node.isMachine, session.isOn(node.id) { session.focus(node.id) }
            }
        }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
            .onChanged { value in
                if dragging == nil {
                    if !session.selection.contains(node.id) { session.selection = [node.id] }
                    dragging = (session.selection, .zero)
                }
                dragging?.translation = value.translation
            }
            .onEnded { _ in
                guard let dragging else { return }
                for id in dragging.ids {
                    if let moved = session.node(id).map({ position(of: $0) }) {
                        session.move(id, to: snapped(CanvasPoint(x: moved.x, y: moved.y)))
                    }
                }
                self.dragging = nil
            })
        .contextMenu { contextMenu(node) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Open Window") { openStation(node.id) }
        .accessibilityFocused($focusedNode, equals: node.id)
    }

    private func toggleSelection(_ id: UUID) {
        if session.selection.contains(id) {
            session.selection.remove(id)
        } else {
            session.selection.insert(id)
        }
    }

    @ViewBuilder
    private func contextMenu(_ node: NetworkNode) -> some View {
        if node.isMachine {
            let on = session.isOn(node.id)
            Button(on ? "Power Off" : "Power On") { session.togglePower(node.id) }
            Button("Cold Boot") { session.coldBoot(node.id) }
            Button("Break") { session.pressBreak(node.id) }
                .disabled(!on)
            Button(session.isSuspended(node.id) ? "Resume Station" : "Suspend Station") {
                session.setSuspended(node.id, !session.isSuspended(node.id))
            }
            .disabled(!on)
            Divider()
            Button("Open Window") {
                if !on { session.powerOn(node.id) }
                openStation(node.id)
            }
            Button("Show Debugger") { openDebugger(node.id) }
                .disabled(!on)
            Button("Hardware…") { openHardware(node.id) }
            Button("Insert Disc in Drive 0…") { session.chooseDisc(for: node.id, drive: 0) }
            Button("Eject Drive 0") { session.eject(node.id, drive: 0) }
                .disabled(node.discs[0] == nil)
            if node.kind == .fileServer {
                Divider()
                Button("Start File Server") { session.startFileServer(node.id) }
                Button("Add Files…") { session.chooseFilesForServer(node.id) }
            }
            if node.kind == .printServer {
                Divider()
                Button("Start Printer Server") { session.startPrinterServer(node.id) }
                OpenPrintCentreButton()
            }
            Divider()
            Button("Duplicate") { session.duplicate(node.id) }
        }
        Button("Remove…", role: .destructive) {
            removing = session.selection.contains(node.id) ? session.selection : [node.id]
        }
    }

    private var removalTitle: String {
        guard let removing else { return "" }
        if removing.count == 1, let node = session.node(removing.first!) {
            return "Remove “\(node.name)” from the network?"
        }
        return "Remove \(removing.count) items from the network?"
    }

    // MARK: Palette

    enum PaletteItem: String, CaseIterable, Identifiable {
        case modelB, master128, fileServer, level2FileServer, printServer, clock

        var id: String { rawValue }

        var title: String {
            switch self {
            case .modelB: "BBC Model B"
            case .master128: "Master 128"
            case .fileServer: "File Server"
            case .level2FileServer: "Level 2 File Server"
            case .printServer: "Printer Server"
            case .clock: "Clock"
            }
        }

        var kind: NetworkNode.Kind {
            switch self {
            case .modelB, .master128: .station
            case .fileServer, .level2FileServer: .fileServer
            case .printServer: .printServer
            case .clock: .clock
            }
        }

        var symbol: String {
            switch self {
            case .modelB: "desktopcomputer"
            case .master128: "desktopcomputer.and.macbook"
            case .fileServer: "externaldrive.connected.to.line.below"
            case .level2FileServer: "externaldrive.badge.person.crop"
            case .printServer: "printer"
            case .clock: "metronome"
            }
        }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
            ForEach(PaletteItem.allCases) { item in
                Button {
                    // At the end of its row, along the trunk.
                    add(item, at: session.project.nextPosition(for: item.kind))
                } label: {
                    // The symbols are different widths: a column for them,
                    // so the titles line up.
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .frame(width: 24)
                        Text(item.title)
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item == .clock && session.project.hasClock)
                .draggable(item.rawValue) {
                    Label(item.title, systemImage: item.symbol)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .help(item == .clock && session.project.hasClock ? "The network has its clock" : "Drag onto the network, or click to add")
            }
        }
        .frame(width: 168)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    /// "saved:UUID", a saved machine dragged from the palette.
    static func savedMachineID(fromDrag item: String) -> UUID? {
        item.hasPrefix("saved:") ? UUID(uuidString: String(item.dropFirst(6))) : nil
    }

    /// The user's saved machine configurations, under the palette.
    @ViewBuilder
    private var savedMachinesPalette: some View {
        let saved = MachineConfigurations.shared.machines
        if !saved.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("My Machines")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                ForEach(saved) { machine in
                    Button {
                        add(machine, at: session.project.nextPosition(for: .station))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: machine.setup.model.isMaster ? "desktopcomputer.and.macbook" : "desktopcomputer")
                                .frame(width: 24)
                            Text(machine.name)
                                .lineLimit(1)
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .draggable("saved:\(machine.id.uuidString)") {
                        Label(machine.name, systemImage: "desktopcomputer")
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .help([machine.setup.model.displayName, machine.setup.fittedSummary].filter { !$0.isEmpty }.joined(separator: " · ")
                          + ". Drag onto the network, or click to add")
                }
            }
            .frame(width: 168)
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
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
        let view = viewPoint(CGPoint(x: point.x, y: point.y))
        let margin = 140 * zoom
        guard view.x < margin + 180 || view.x > size.width - margin || view.y < margin || view.y > size.height - margin else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            centre = CGPoint(x: point.x, y: (centre.y + point.y) / 2)
        }
        rememberView()
    }

    // MARK: Problems and zoom

    private var problems: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.project.problems, id: \.self) { problem in
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)
            Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Divider().frame(height: 16).padding(.horizontal, 4)
            Button { fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Show the whole network")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
    }

    private func setZoom(_ value: Double) {
        withAnimation(.easeOut(duration: 0.15)) {
            zoom = value.clamped(to: Self.zoomRange)
        }
        rememberView()
    }

    /// Zooms and centres to show every node, and the room's other machines.
    func fit(animated: Bool = true) {
        let points = session.project.nodes.map { CGPoint(x: $0.position.x, y: $0.position.y) } + remoteLayout.map(\.point)
        guard !points.isEmpty else { return }
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = (xs.max()! - xs.min()!) + MachineCard.width + 80
        let height = (ys.max()! - ys.min()!) + MachineCard.height + 80
        // Clear of the palette, on the left.
        let palette = 200.0
        let fitted = min((size.width - palette) / width, size.height / height, 1.5).clamped(to: Self.zoomRange)
        withAnimation(animated ? .easeInOut(duration: 0.25) : nil) {
            zoom = fitted
            centre = CGPoint(x: (xs.max()! + xs.min()!) / 2 - palette / 2 / fitted, y: (ys.max()! + ys.min()!) / 2)
        }
        rememberView()
    }

    private func scrolled(_ delta: CGSize, zooming: Bool, at location: CGPoint) {
        if zooming {
            // Keep the point under the pointer where it is.
            let before = canvasPoint(location)
            zoom = (zoom * (1 - delta.height / 200)).clamped(to: Self.zoomRange)
            let after = canvasPoint(location)
            centre.x += before.x - after.x
            centre.y += before.y - after.y
        } else {
            centre.x -= delta.width / zoom
            centre.y -= delta.height / zoom
        }
        rememberView()
    }

    private func rememberView() {
        let zoom = zoom, centre = centre
        session.update {
            $0.canvas.zoom = zoom
            $0.canvas.centre = CanvasPoint(x: centre.x, y: centre.y)
        }
    }

    // MARK: Geometry

    /// Where a node is drawn, in canvas points, allowing for a drag.
    /// Where the room's other machines go: along the end of the stations'
    /// row, after everything of this network's.
    private var remoteLayout: [(station: StationView, point: CGPoint)] {
        let remote = session.remoteStations
        guard !remote.isEmpty else { return [] }
        let stations = session.project.nodes.filter { $0.kind == .station }
        let y = stations.isEmpty ? 0 : stations.map(\.position.y).sorted()[stations.count / 2]
        let x = (session.project.nodes.map(\.position.x).max() ?? -NetworkProject.columnSpacing) + NetworkProject.columnSpacing
        return remote.enumerated().map { index, station in
            (station, CGPoint(x: x + Double(index) * NetworkProject.columnSpacing, y: y))
        }
    }

    private func position(of node: NetworkNode) -> CGPoint {
        var point = CGPoint(x: node.position.x, y: node.position.y)
        if let dragging, dragging.ids.contains(node.id) {
            point.x += dragging.translation.width / zoom
            point.y += dragging.translation.height / zoom
        }
        return point
    }

    private func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - centre.x) * zoom + size.width / 2, y: (point.y - centre.y) * zoom + size.height / 2)
    }

    private func canvasPoint(_ point: CGPoint) -> CanvasPoint {
        CanvasPoint(x: (point.x - size.width / 2) / zoom + centre.x, y: (point.y - size.height / 2) / zoom + centre.y)
    }

    private func snapped(_ point: CanvasPoint) -> CanvasPoint {
        guard session.project.canvas.snapToGrid else { return point }
        return CanvasPoint(x: (point.x / Self.grid).rounded() * Self.grid, y: (point.y / Self.grid).rounded() * Self.grid)
    }
}

/// The shared bus: a backbone between the rows of machines, and a drop from
/// each to it. It's a picture of a shared medium, not of the cabling.
struct BusDrawing: View {
    let nodes: [NetworkNode]
    let position: (NetworkNode) -> CGPoint
    let zoom: Double
    /// The nodes that are on.
    let lit: Set<UUID>
    /// The nodes sending just now: their drops glow.
    let transmitting: Set<UUID>
    /// Machines in the network's Internet room, on other Macs: where their
    /// cards are, and whether they're online.
    var remote: [(point: CGPoint, online: Bool)] = []

    var body: some View {
        Canvas { context, _ in
            guard nodes.count + remote.count > 1 else { return }
            let points = nodes.map { (node: $0, point: position($0)) }
            let ys = points.map(\.point.y)
            let busY = ys.isEmpty ? remote[0].point.y : (ys.min()! + ys.max()!) / 2
            let xs = points.map(\.point.x) + remote.map(\.point.x)
            let lineWidth = max(1.5, 3 * zoom)
            var backbone = Path()
            backbone.move(to: CGPoint(x: xs.min()!, y: busY))
            backbone.addLine(to: CGPoint(x: xs.max()!, y: busY))
            context.stroke(backbone, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            for (node, point) in points {
                var drop = Path()
                drop.move(to: point)
                drop.addLine(to: CGPoint(x: point.x, y: busY))
                let on = lit.contains(node.id) || node.kind == .clock
                let sending = transmitting.contains(node.id)
                if sending {
                    context.stroke(drop, with: .color(.green.opacity(0.35)), style: StrokeStyle(lineWidth: lineWidth * 3, lineCap: .round))
                }
                context.stroke(drop, with: .color(sending ? .green : on ? Color.accentColor.opacity(0.55) : .secondary.opacity(0.3)),
                               style: StrokeStyle(lineWidth: lineWidth * 0.8, lineCap: .round, dash: on ? [] : [4 * zoom, 4 * zoom]))
                let tap = CGRect(x: point.x - lineWidth * 1.5, y: busY - lineWidth * 1.5, width: lineWidth * 3, height: lineWidth * 3)
                context.fill(Path(ellipseIn: tap), with: .color(on ? Color.accentColor : .secondary.opacity(0.5)))
            }
            // Remote machines: through the Internet gateway, drawn apart.
            for (point, online) in remote {
                var drop = Path()
                drop.move(to: point)
                drop.addLine(to: CGPoint(x: point.x, y: busY))
                context.stroke(drop, with: .color(online ? .teal.opacity(0.7) : .secondary.opacity(0.3)),
                               style: StrokeStyle(lineWidth: lineWidth * 0.8, lineCap: .round, dash: [6 * zoom, 3 * zoom]))
                let tap = CGRect(x: point.x - lineWidth * 1.5, y: busY - lineWidth * 1.5, width: lineWidth * 3, height: lineWidth * 3)
                context.fill(Path(ellipseIn: tap), with: .color(online ? .teal : .secondary.opacity(0.5)))
            }
        }
    }
}

/// A machine in the network's Internet room, on someone else's Mac (a BBC
/// Micro in MacBeeb, or an Archimedes in MacArch): who it is and whose,
/// whether it's online, and how far away.
struct RemoteStationCard: View {
    let station: StationView
    let participant: ParticipantView?
    /// Its screen, if its owner shares it.
    var screen: CGImage?

    static let width = 236.0
    static var height: Double { 160.0 }

    /// An Archimedes, from MacArch.
    private var isArchimedes: Bool { participant?.app == "MacArch" }

    /// What sort of machine, from the app it's in.
    private var family: String {
        switch participant?.app {
        case "MacArch": "Archimedes, in MacArch"
        case "MacBeeb": "BBC Micro, in MacBeeb"
        case let app?: "in \(app)"
        case nil: "on another Mac"
        }
    }

    /// The picture's shape: a BBC's, or an Archimedes monitor's 4:3.
    private var aspect: CGFloat { isArchimedes ? 4.0 / 3.0 : Renderer.aspect }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let screen {
                Image(decorative: screen, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        Image(systemName: "globe")
                            .font(.caption)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(5)
                    }
            }
            HStack {
                if isArchimedes {
                    Image(systemName: "desktopcomputer")
                        .font(.title2)
                        .foregroundStyle(station.online ? .teal : .secondary)
                }
                Image(systemName: "globe")
                    .font(.title2)
                    .foregroundStyle(station.online ? .teal : .secondary)
                Spacer()
                if let rtt = participant?.rttMs, station.online {
                    Text("\(rtt) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(station.online ? "Online" : "Offline")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((station.online ? Color.teal : Color.secondary).opacity(0.18), in: Capsule())
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                StationBadge(number: station.station)
                VStack(alignment: .leading, spacing: 1) {
                    Text(station.label)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(station.kind) · \(participant?.name ?? "someone else")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(family)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(width: Self.width, height: screen == nil ? Self.height : MachineCard.height)
        .background(.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(station.online ? Color.teal.opacity(0.8) : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .opacity(station.online ? 1 : 0.6)
        .help("Station \(station.station), \(station.label): a \(station.kind) on \(participant?.name ?? "another")'s Mac, in this network's Internet room")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Remote station \(station.station), \(station.label), \(station.kind), \(participant?.name ?? ""), \(station.online ? "online" : "offline")")
    }
}

/// A machine on the canvas: its screen, live, and who it is.
struct MachineCard: View {
    let session: NetworkSession
    let node: NetworkNode
    let selected: Bool
    let problem: String?

    static let width = 236.0
    static let height = 230.0

    var body: some View {
        let controller = session.controllers[node.id]
        VStack(alignment: .leading, spacing: 8) {
            screen(controller)
            HStack(spacing: 8) {
                StationBadge(number: node.stationNumber, problem: problem != nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if session.transmitting.contains(node.id) {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                        .help("Sending on the network")
                        .accessibilityLabel("Sending")
                }
                StateIndicator(state: state(controller))
            }
            if node.kind != .station, let controller {
                Label(controller.consoleLine ?? "Starting…", systemImage: "text.alignleft")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("The server's console: its last line")
            }
        }
        .padding(10)
        .frame(width: Self.width)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.accentColor : problem != nil ? Color.orange.opacity(0.8) : Color.secondary.opacity(0.2),
                              lineWidth: selected ? 2.5 : 1)
        }
        .shadow(color: .black.opacity(selected ? 0.18 : 0.10), radius: selected ? 10 : 5, y: 2)
        .help(problem ?? "\(node.name): double-click to open its window")
        .accessibilityLabel("\(node.name), \(subtitle), \(state(controller).label)")
    }

    private var subtitle: String {
        let model = node.setup?.summary ?? ""
        return node.kind == .station ? model : "\(node.kind.displayName) · \(model)"
    }

    @ViewBuilder
    private func screen(_ controller: MachineController?) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black
            if let controller {
                StationThumbnail(cache: session.thumbnails, id: node.id, host: controller.host)
            } else if controller == nil {
                VStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.title2)
                    Text("Off")
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if node.kind != .station {
                Label(node.kind == .fileServer ? (node.level == .level2 ? "LEVEL 2 FILE SERVER" : "FILE SERVER") : "PRINTER SERVER",
                      systemImage: node.kind == .fileServer ? "externaldrive.connected.to.line.below" : "printer")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .padding(6)
            }
        }
        .aspectRatio(Renderer.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.black.opacity(0.4), lineWidth: 1)
        }
    }

    private func state(_ controller: MachineController?) -> StateIndicator.State {
        guard let controller else { return .off }
        if controller.debugStop != nil { return .debugger }
        if session.paused { return .networkPaused }
        if controller.paused { return .suspended }
        return .on
    }
}

/// A machine's screen, from the thumbnail cache.
struct StationThumbnail: View {
    let cache: ThumbnailCache
    let id: UUID
    let host: EmulatorHost

    var body: some View {
        Group {
            if let image = cache.images[id] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
            } else {
                Color.black
            }
        }
        .onAppear { cache.show(id, host: host) }
        .onDisappear { cache.hide(id) }
    }
}

struct StationBadge: View {
    let number: Int?
    var problem = false

    var body: some View {
        Text(number.map(String.init) ?? "–")
            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: 30, minHeight: 22)
            .padding(.horizontal, 3)
            .background(problem ? Color.orange : Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(number.map { "Station \($0)" } ?? "No station number")
    }
}

/// On, off, suspended: a shape as well as a colour, so it doesn't rely on
/// colour alone.
struct StateIndicator: View {
    enum State {
        case on, off, suspended, networkPaused, debugger

        var label: String {
            switch self {
            case .on: "On"
            case .off: "Off"
            case .suspended: "Suspended"
            case .networkPaused: "Paused"
            case .debugger: "Stopped in the debugger"
            }
        }

        var symbol: String {
            switch self {
            case .on: "circle.fill"
            case .off: "circle"
            case .suspended: "pause.circle.fill"
            case .networkPaused: "pause.circle"
            case .debugger: "ladybug.circle.fill"
            }
        }

        var colour: Color {
            switch self {
            case .on: .green
            case .off: .secondary
            case .suspended: .orange
            case .networkPaused: .blue
            case .debugger: .red
            }
        }
    }

    let state: State

    var body: some View {
        Image(systemName: state.symbol)
            .font(.system(size: 13))
            .foregroundStyle(state.colour)
            .help(state.label)
            .accessibilityLabel(state.label)
    }
}

/// The network's clock on the canvas.
struct ClockCard: View {
    let node: NetworkNode
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "metronome")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
                .frame(width: 56, height: 56)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            Text("Clock")
                .font(.headline)
            Text(Self.rateText(node.clockRate ?? NetworkNode.defaultClockRate))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 130)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2.5 : 1)
        }
        .shadow(color: .black.opacity(selected ? 0.18 : 0.10), radius: selected ? 10 : 5, y: 2)
        .help("The network's clock: every Econet needs one")
        .accessibilityLabel("Network clock, \(Self.rateText(node.clockRate ?? NetworkNode.defaultClockRate))")
    }

    static func rateText(_ rate: Int) -> String {
        "\(rate / 1000) kbit/s"
    }
}

/// Scroll-wheel and trackpad scrolling over the canvas, which SwiftUI
/// doesn't offer: pans, or with ⌘ zooms.
struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (CGSize, Bool, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: (CGSize, Bool, CGPoint) -> Void = { _, _, _ in }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
                self.onScroll(CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale),
                              event.modifierFlags.contains(.command),
                              CGPoint(x: point.x, y: self.bounds.height - point.y))
                return nil
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
