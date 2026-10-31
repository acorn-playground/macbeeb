import BeebHost
import BeebNetwork
import CGtk
import Foundation

/// A card on the canvas: a machine, the clock, or a machine in the
/// network's Internet room. Its widget is placed (and scaled) by the
/// canvas.
@MainActor
protocol CanvasCard: AnyObject {
    var widget: Widget { get }
}

/// A machine on the canvas: its screen, live, and who it is.
@MainActor
final class MachineCard: CanvasCard {
    static let width = 236.0
    static let height = 230.0
    static let screenWidth: Int32 = 216
    static var screenHeight: Int32 { Int32((Double(screenWidth) / Renderer.aspect).rounded()) }

    let id: UUID
    let widget: Widget
    let picture = StationScreenView()
    private let off: Widget
    private let chip: Box
    private let chipIcon = Icon("network-server-symbolic", size: 10)
    private let chipLabel = Label("", style: "network-chip-label")
    private var badge: Label
    private let badgeHolder = Bin()
    private let name = Label("", style: "heading")
    private let subtitle = Label("", style: "caption", "dim-label")
    private let sending = Icon("network-transmit-symbolic", size: 14)
    private let light = StateLight()
    private let console = ConsoleLineView()
    private let consoleRow: Box
    private var problem = false
    private var number: Int?

    init(node: NetworkNode) {
        id = node.id
        let (picture, chipIcon, chipLabel, badgeHolder, name, subtitle, sending, light, console) =
            (self.picture, self.chipIcon, self.chipLabel, self.badgeHolder, self.name, self.subtitle, self.sending, self.light,
             self.console)
        let screenBase = Bin().style("network-screen").size(width: Self.screenWidth, height: Self.screenHeight)
        let off = Box(.vertical, spacing: 4) {
            Icon("system-shutdown-symbolic", size: 22)
            Label("Off", style: "caption").centred()
        }
        .style("network-screen-off")
        .align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER)
        .canTarget(false)
        self.off = off
        let chip = Box(.horizontal, spacing: 4) { chipIcon; chipLabel }
        self.chip = chip
        chip.style("network-chip").align(horizontal: GTK_ALIGN_END, vertical: GTK_ALIGN_END).margin(6).canTarget(false)
        let screen = Overlay(screenBase) {
            picture.area
            off
            chip
        }
        gtk_widget_set_overflow(screen.widget, GTK_OVERFLOW_HIDDEN)
        screen.style("network-screen")

        name.ellipsize().maxWidthChars(1).expand(horizontal: true)
        subtitle.ellipsize().maxWidthChars(1).expand(horizontal: true)
        sending.style("success").tooltip("Sending on the network")
        let badge = StationNumberBadge(node.stationNumber)
        self.badge = badge
        badgeHolder.child = badge
        let identity = Box(.horizontal, spacing: 8) {
            badgeHolder
            Box(.vertical, spacing: 1) { name; subtitle }.align(vertical: GTK_ALIGN_CENTER).expand(horizontal: true)
            sending
            light.area
        }
        let consoleRow = Box(.horizontal, spacing: 6) {
            Icon("format-justify-left-symbolic", size: 12).style("dim-label")
            console.area
        }
        self.consoleRow = consoleRow
        consoleRow.tooltip("The server's console: its last line")
        let card = Box(.vertical, spacing: 8) {
            screen
            identity
            consoleRow
        }
        card.style("network-card").size(width: Int32(Self.width))
        card.focusable(true)
        widget = card
    }

    /// Shows the node as it is now.
    func update(_ node: NetworkNode, session: NetworkSession, selected: Bool, problem message: String?) {
        let controller = session.controllers[node.id]
        name.text = node.name
        let model = node.setup?.summary ?? ""
        let subtitleText = node.kind == .station ? model : "\(node.kind.displayName) · \(model)"
        subtitle.text = subtitleText
        if node.stationNumber != number || (message != nil) != problem {
            number = node.stationNumber
            problem = message != nil
            badge = StationNumberBadge(node.stationNumber, problem: problem)
            badgeHolder.child = badge
        }
        widget.setStyle("selected", selected)
        widget.setStyle("problem", message != nil)
        off.isVisible = controller == nil
        picture.area.isVisible = controller != nil
        if controller == nil { picture.image = nil }
        chip.isVisible = node.kind != .station
        // (An icon set again is laid out again, even if it's the same.)
        let chipIconName = node.kind == .printServer ? "printer-network-symbolic" : "network-server-symbolic"
        if chipIcon.name != chipIconName { chipIcon.name = chipIconName }
        if node.kind == .fileServer {
            chipLabel.text = node.level == .level1 ? "FILE SERVER" : "\(node.level.displayName.uppercased()) FILE SERVER"
        } else if node.kind == .printServer {
            chipLabel.text = "PRINTER SERVER"
        }
        // (Faded, not hidden: the name beside it stays put.)
        let transmitting = session.transmitting.contains(node.id)
        sending.opacity(transmitting ? 1 : 0)
        let state = StateLight.state(of: node.id, in: session)
        light.state = state
        consoleRow.isVisible = node.kind != .station && controller != nil
        console.text = controller?.consoleLine ?? "Starting…"
        describe(tooltip: message ?? "\(node.name): double-click to open its window",
                 label: "\(node.name), \(subtitleText), \(state.label)" + (transmitting ? ", sending" : "")
                    + (selected ? ", selected" : ""))
    }

    private var described: (String, String)?

    /// Its tooltip and what screen readers say (when they change).
    private func describe(tooltip: String, label: String) {
        guard described?.0 != tooltip || described?.1 != label else { return }
        described = (tooltip, label)
        widget.tooltip(tooltip)
        widget.accessibleLabel(label)
    }

    func setImage(_ image: PlatformImage?) {
        picture.image = image
    }
}

/// A server's console line: drawn, not laid out, as it changes with every
/// request the server answers.
@MainActor
final class ConsoleLineView {
    let area: DrawingArea
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            area.queueDraw()
            area.accessibleLabel(text)
        }
    }
    private static let font = "Monospace 8"

    init() {
        area = DrawingArea(height: 15) { _, _, _ in }
        area.expand(horizontal: true).align(vertical: GTK_ALIGN_CENTER)
        let area = self.area
        // (The area's draw function keeps the view.)
        area.setDraw { [self] cairo, width, height in
            cairo.foreground(of: area, alpha: 0.55)
            let size = cairo.measure(self.text, font: Self.font)
            cairo.text(self.text, x: 0, y: (height - size.height) / 2, font: Self.font, width: width)
        }
    }
}

/// The network's clock on the canvas.
@MainActor
final class ClockCard: CanvasCard {
    let id: UUID
    let widget: Widget
    private let rate = Label("", style: "caption", "dim-label")

    init(node: NetworkNode) {
        id = node.id
        let rate = self.rate
        let face = Bin(Icon("preferences-system-time-symbolic", size: 26).align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER))
            .style("clock-face", "accent")
            .size(width: 56, height: 56)
            .align(horizontal: GTK_ALIGN_CENTER)
        let card = Box(.vertical, spacing: 6) {
            face
            Label("Clock", style: "heading").centred()
            rate.centred()
        }
        card.style("network-card", "clock-card").size(width: 130)
        card.focusable(true)
        card.tooltip("The network's clock: every Econet needs one")
        widget = card
    }

    func update(_ node: NetworkNode, selected: Bool) {
        let text = Self.rateText(node.clockRate ?? NetworkNode.defaultClockRate)
        rate.text = text
        widget.setStyle("selected", selected)
        let label = "Network clock, \(text)" + (selected ? ", selected" : "")
        if label != described {
            described = label
            widget.accessibleLabel(label)
        }
    }

    private var described = ""

    static func rateText(_ rate: Int) -> String {
        "\(rate / 1000) kbit/s"
    }
}

/// A machine in the network's Internet room, on someone else's computer
/// (a BBC Micro in MacBeeb, or an Archimedes in MacArch): who it is and
/// whose, whether it's online, and how far away.
@MainActor
final class RemoteStationCard: CanvasCard {
    static let width = 236.0
    static let height = 160.0

    let station: Int
    let widget: Widget
    private let screen: Overlay
    private let picture = StationScreenView()
    private let archimedes = Icon("computer-symbolic", size: 22)
    private let globe = Icon("web-browser-symbolic", size: 22)
    private let rtt = Label("", style: "caption", "dim-label", "numeric")
    private let online = Label("", style: "online-pill")
    private let badgeHolder = Bin()
    private let label = Label("", style: "heading")
    private let detail = Label("", style: "caption", "dim-label")
    private let family = Label("", style: "caption", "dim-label")
    private var number: Int?

    init(station: StationView) {
        self.station = station.station
        let (picture, archimedes, globe, rtt, online, badgeHolder, label, detail, family) =
            (self.picture, self.archimedes, self.globe, self.rtt, self.online, self.badgeHolder, self.label, self.detail, self.family)
        let base = Bin().style("network-screen").size(width: MachineCard.screenWidth, height: MachineCard.screenHeight)
        let chip = Bin(Icon("web-browser-symbolic", size: 12)).style("network-chip", "remote-globe")
            .align(horizontal: GTK_ALIGN_START, vertical: GTK_ALIGN_START).margin(5)
        let screen = Overlay(base) { picture.area; chip }
        self.screen = screen
        gtk_widget_set_overflow(screen.widget, GTK_OVERFLOW_HIDDEN)
        for text in [label, detail, family] {
            text.ellipsize().maxWidthChars(1).expand(horizontal: true)
        }
        let status = Box(.horizontal, spacing: 6) {
            archimedes
            globe
            NetworkRowSpacer()
            rtt.align(vertical: GTK_ALIGN_CENTER)
            online.align(vertical: GTK_ALIGN_CENTER)
        }
        let identity = Box(.horizontal, spacing: 8) {
            badgeHolder
            Box(.vertical, spacing: 1) { label; detail; family }.expand(horizontal: true)
        }
        let card = Box(.vertical, spacing: 8) {
            screen
            status
            Spacer()
            identity
        }
        card.style("network-card", "remote").size(width: Int32(Self.width), height: Int32(Self.height))
        widget = card
    }

    func update(_ station: StationView, participant: ParticipantView?, screen image: PlatformImage?) {
        let isArchimedes = participant?.app == "MacArch"
        let familyText = switch participant?.app {
        case "MacArch": "Archimedes, in MacArch"
        case "MacBeeb": "BBC Micro, in MacBeeb"
        case let app?: "in \(app)"
        case nil: "on another computer"
        }
        screen.isVisible = image != nil
        picture.image = image
        archimedes.isVisible = isArchimedes
        for icon in [archimedes, globe] {
            icon.setStyle("teal", station.online)
            icon.setStyle("dim-label", !station.online)
        }
        if let ms = participant?.rttMs, station.online {
            rtt.text = "\(ms) ms"
            rtt.isVisible = true
        } else {
            rtt.isVisible = false
        }
        online.text = station.online ? "Online" : "Offline"
        online.setStyle("online", station.online)
        if number != station.station {
            number = station.station
            badgeHolder.child = StationNumberBadge(station.station, remote: true)
        }
        label.text = station.label
        let owner = participant?.name ?? "someone else"
        detail.text = "\(station.kind) · \(owner)"
        family.text = familyText
        widget.setStyle("online", station.online)
        widget.opacity(station.online ? 1 : 0.6)
        widget.tooltip("Station \(station.station), \(station.label): a \(station.kind) on \(participant?.name ?? "another")'s computer, in this network's Internet room")
        widget.accessibleLabel("Remote station \(station.station), \(station.label), \(station.kind), \(participant?.name ?? ""), \(station.online ? "online" : "offline")")
    }

    var height: Double { screen.isVisible ? MachineCard.height : Self.height }
}
