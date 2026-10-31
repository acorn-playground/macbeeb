import BeebCore
import BeebHost
import BeebNetwork
import CGtk
import Foundation
import Observation

/// Follows the network's trace for the Distributed Mandelbrot demo, for
/// the studio's Mandelbrot view. It reads the frames from when it's first
/// shown until the studio closes, so switching views doesn't lose a
/// render. It only watches: what's drawn is what the workers sent. (The
/// Mac's is in NetworkMandelbrotView.)
@MainActor @Observable
final class MandelbrotFeed {
    private(set) var observer = MandelbrotObserver()
    @ObservationIgnored private weak var session: NetworkSession?
    @ObservationIgnored private var lastFrame: Int?
    @ObservationIgnored private var polling = false
    /// Tracing was off, and the view turned it on.
    @ObservationIgnored private var turnedTracingOn = false

    static let refresh = 0.25

    func start(_ session: NetworkSession) {
        self.session = session
        let network = session.runtime.network
        if !network.isTracing {
            network.setTracing(true)
            turnedTracingOn = true
        }
        guard !polling else { return }
        polling = true
        poll()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refresh))
                guard let self else { return }
                self.poll()
            }
        }
    }

    /// The view's gone: put tracing back as it was.
    func hidden() {
        if turnedTracingOn {
            session?.runtime.network.setTracing(false)
            turnedTracingOn = false
        }
    }

    /// Forget what's been seen, and carry on from here.
    func reset() {
        observer = MandelbrotObserver()
        picture = nil
    }

    private func poll() {
        guard let session else { return }
        let newer = session.runtime.network.frames(after: lastFrame)
        var observer = observer
        if !newer.isEmpty {
            observer.observe(newer)
            lastFrame = newer.last?.id
        }
        observer.advance(to: session.status.cycles)
        // Only publish a change (it's a big value).
        if observer.now != self.observer.now || !newer.isEmpty { self.observer = observer }
    }

    // MARK: The picture

    @ObservationIgnored private var picture: (key: PictureKey, image: PlatformImage)?

    private struct PictureKey: Equatable {
        var run: UInt32?
        var accepted: Int
        var authentic: Bool
        var max: Int
    }

    /// What's not been drawn yet: the picture's dark ground.
    static let ground: UInt32 = 0x1F1F1F

    /// The accepted tiles' counts as colours; missing pixels are the ground.
    func image(authentic: Bool) -> PlatformImage? {
        let key = PictureKey(run: observer.runId, accepted: observer.tilesCompleted, authentic: authentic, max: observer.maxIterations)
        if let picture, picture.key == key { return picture.image }
        let width = MandelbrotProtocol.imageWidth, height = MandelbrotProtocol.imageHeight
        let observer = self.observer
        let max = observer.maxIterations
        let table = (0 ... 255).map { n in authentic ? Self.mode5(n, max: max) : Self.gradient(n, max: max) }
        var pixels = [UInt32](repeating: Self.ground, count: width * height)
        for i in 0 ..< width * height where observer.covered[i] {
            let (r, g, b) = table[Int(observer.image[i])]
            pixels[i] = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        }
        guard let image = Platform.image(pixels: pixels, width: width, height: height) else { return nil }
        picture = (key, image)
        return image
    }

    /// As the coordinator shows it: colour 0 if `n == max`, otherwise
    /// `1 + (n - 1) mod 3`, in black, blue, cyan and yellow.
    static func mode5(_ n: Int, max: Int) -> (UInt8, UInt8, UInt8) {
        let colour = n == max ? 0 : 1 + (n - 1) % 3
        return [(0, 0, 0), (0, 0, 255), (0, 255, 255), (255, 255, 0)][colour]
    }

    /// Smoother: the count, on a log scale, through deep blue, white and
    /// orange; the set itself is black.
    static func gradient(_ n: Int, max: Int) -> (UInt8, UInt8, UInt8) {
        guard n < max, max > 1 else { return (0, 0, 0) }
        let t = log(Double(Swift.max(n, 1))) / log(Double(max))
        let stops: [(Double, Double, Double, Double)] = [
            (0, 0, 7, 100), (0.16, 32, 107, 203), (0.42, 237, 255, 255), (0.6425, 255, 170, 0), (0.8575, 120, 20, 0), (1, 40, 0, 10),
        ]
        let upper = stops.firstIndex { $0.0 >= t } ?? stops.count - 1
        let lower = Swift.max(upper - 1, 0)
        let (a, b) = (stops[lower], stops[upper])
        let f = b.0 > a.0 ? (t - a.0) / (b.0 - a.0) : 0
        func mix(_ x: Double, _ y: Double) -> UInt8 { UInt8(clamping: Int((x + (y - x) * f).rounded())) }
        return (mix(a.1, b.1), mix(a.2, b.2), mix(a.3, b.3))
    }
}

/// The Distributed Mandelbrot demo, as its frames show it: the picture
/// from the tiles the coordinator accepted, the tiles out with workers,
/// and what each worker's done.
@MainActor
final class NetworkMandelbrotView {
    let session: NetworkSession
    let feed: MandelbrotFeed
    let root: Widget
    private let content = Stack()
    private let picture: DrawingArea
    private let progress = Label("", style: "dim-label", "numeric")
    private let clear: Button
    private var authentic = UserDefaults.standard.object(forKey: "mandelbrotAuthenticPalette") as? Bool ?? true
    private var showsInFlight = UserDefaults.standard.object(forKey: "mandelbrotShowsInFlight") as? Bool ?? true

    // The sidebar's rows.
    private let bar = ProgressBar()
    private let accepted = ActionRow("Accepted").property()
    private let received = ActionRow("Received").property()
    private let inFlight = ActionRow("In flight").property()
    private let time = ActionRow("Time").property()
    private let coordinator = ActionRow("Coordinator").property()
    private let run = ActionRow("Run").property()
    private let iterations = ActionRow("Iterations").property()
    private let workers = PreferencesGroup(title: "Workers")
    private var workerRows: [UInt8: MandelbrotWorkerRow] = [:]
    private var workerOrder: [UInt8] = []
    private let noWorkers = ActionRow("None seen yet")
    private let gaps = PreferencesGroup(title: "Gaps")
    private let missed = ActionRow("")
    private let malformed = ActionRow("")

    private static let palette: [UInt32] = [0xFF9500, 0x34C759, 0xFF2D55, 0xAF52DE, 0x30B0C7, 0xFF3B30, 0xFFCC00, 0x00C7BE, 0x5856D6, 0xA2845E]

    /// MODE 5's pixels are twice as wide as they're tall.
    static let aspect = Double(MandelbrotProtocol.imageWidth * 2) / Double(MandelbrotProtocol.imageHeight)

    init(session: NetworkSession, feed: MandelbrotFeed) {
        self.session = session
        self.feed = feed
        picture = DrawingArea { _, _, _ in }
        clear = Button("Clear", icon: "user-trash-symbolic") { feed.reset() }
        let box = Box(.vertical)
        root = box

        let palette = CheckButton("Authentic MODE 5 palette", isOn: authentic) { [self] on in
            self.authentic = on
            UserDefaults.standard.set(on, forKey: "mandelbrotAuthenticPalette")
            self.picture.queueDraw()
        }
        palette.tooltip("The coordinator's own four colours, or a smoother gradient from the same counts")
        let flight = CheckButton("Tiles in flight", isOn: showsInFlight) { [self] on in
            self.showsInFlight = on
            UserDefaults.standard.set(on, forKey: "mandelbrotShowsInFlight")
            self.picture.queueDraw()
        }
        flight.tooltip("Outline the tiles given out and not yet accepted, in their worker's colour")
        clear.style("flat").tooltip("Forget what's been seen, and networkFollow from here")
        let header = Box(.horizontal, spacing: 14) {
            palette
            flight
            NetworkRowSpacer()
            progress
            clear
        }
        header.margin(horizontal: 12, vertical: 6)

        let empty = StatusPage(icon: "view-app-grid-symbolic", title: "No Mandelbrot Traffic Yet",
                               description: "When the Distributed Mandelbrot demo runs on this network, its picture builds up here from the frames on the line: run MANDEL on one machine, and CLUSTER to start the workers.")
        picture.style("network-backdrop").expand().size(width: 320, height: 240)
        picture.accessibleLabel("The Mandelbrot set, as the workers have drawn it")
        let sidebar = buildSidebar()
        let split = Paned(.horizontal, start: picture, end: sidebar)
        split.resizes(start: true, end: false)
        content.add(split, name: "picture")
        content.add(empty, name: "empty")
        box.append(header)
        box.append(Separator())
        box.append(content.expand())

        picture.setDraw { [self] cairo, width, height in self.draw(cairo, width, height) }
        var alive = true
        root.onDestroy { alive = false }
        root.onMap { [self] in
            self.feed.start(self.session)
            // The sidebar its own width, once the view's laid out.
            MainLoop.after(0) {
                guard alive else { return }
                if split.position < 200 || split.position > split.width - 260 { split.position = max(320, split.width - 320) }
            }
        }
        root.onUnmap { [self] in self.feed.hidden() }
        root.track { [self] in
            let observer = self.feed.observer
            self.update(observer)
        }
        root.keep(self)
    }

    private var observer: MandelbrotObserver { feed.observer }

    // MARK: The picture

    private func draw(_ cairo: Cairo, _ width: Double, _ height: Double) {
        let margin = 12.0
        var w = width - margin * 2, h = w / Self.aspect
        if h > height - margin * 2 {
            h = height - margin * 2
            w = h * Self.aspect
        }
        guard w > 0, h > 0 else { return }
        let x = (width - w) / 2, y = (height - h) / 2
        cairo.color(0.12, 0.12, 0.12)
        cairo.rectangle(x, y, w, h)
        cairo.fill()
        if let image = feed.image(authentic: authentic) {
            cairo.image(image, x: x, y: y, width: w, height: h, smooth: false)
        }
        guard showsInFlight else { return }
        let colours = workerColours
        let sx = w / Double(MandelbrotProtocol.imageWidth), sy = h / Double(MandelbrotProtocol.imageHeight)
        for assignment in observer.inFlight {
            let rx = x + Double(assignment.x) * sx, ry = y + Double(assignment.y) * sy
            let rw = Double(assignment.width) * sx, rh = Double(assignment.height) * sy
            let colour = colours[assignment.station] ?? 0xFFFFFF
            cairo.color(hex: colour, alpha: 0.25)
            cairo.rectangle(rx, ry, rw, rh)
            cairo.fill()
            cairo.color(hex: colour)
            cairo.rectangle(rx + 1, ry + 1, rw - 2, rh - 2)
            cairo.stroke(width: 2)
        }
    }

    /// Each worker's colour, by station, in order.
    private var workerColours: [UInt8: UInt32] {
        Dictionary(uniqueKeysWithValues: observer.sortedWorkers.enumerated().map { ($1.station, Self.palette[$0 % Self.palette.count]) })
    }

    // MARK: The sidebar

    private func buildSidebar() -> Widget {
        let page = PreferencesPage()
        bar.margin(top: 4, bottom: 12)
        let render = PreferencesGroup(title: "Render")
        render.add(bar)
        for row in [accepted, received, inFlight, time, coordinator, run, iterations] { render.add(row) }
        page.add(render)
        workers.add(noWorkers)
        noWorkers.style("dim-label")
        page.add(workers)
        for row in [missed, malformed] {
            adw_action_row_set_title_lines(cast(row.widget), 0)
            gaps.add(row)
        }
        missed.prefix(Icon("dialog-warning-symbolic").style("warning"))
        malformed.prefix(Icon("dialog-warning-symbolic").style("dim-label"))
        page.add(gaps)
        page.add(PreferencesGroup {
            NetworkCaption("Drawn only from the counts the workers sent, for the tiles the coordinator accepted. Nothing is worked out here.")
        })
        page.size(width: 280)
        return page
    }

    private func update(_ observer: MandelbrotObserver) {
        content.visible = observer.isEmpty ? "empty" : "picture"
        clear.isEnabled = !observer.isEmpty
        let total = MandelbrotProtocol.tileCount
        var text = "\(observer.tilesCompleted) of \(total) tiles"
        if let seconds = observer.elapsedSeconds { text += String(format: " · %.1f s", seconds) }
        if observer.completeSeen { text += " · Complete" }
        progress.text = text
        progress.isVisible = !observer.isEmpty

        bar.fraction = Double(observer.tilesCompleted) / Double(total)
        accepted.subtitle = "\(observer.tilesCompleted) of \(total) tiles"
        received.subtitle = "\(observer.received.count) result\(observer.received.count == 1 ? "" : "s")"
        inFlight.subtitle = "\(observer.inFlight.count)"
        time.isVisible = observer.elapsedSeconds != nil
        if let seconds = observer.elapsedSeconds {
            time.subtitle = String(format: "%.1f s emulated", seconds) + (observer.completeSeen ? ", complete" : "")
        }
        coordinator.isVisible = observer.coordinator != nil
        if let station = observer.coordinator { coordinator.subtitle = name(station) }
        run.isVisible = observer.runId != nil
        if let id = observer.runId { run.subtitle = String(format: "&%08X", id) }
        iterations.subtitle = "At most \(observer.maxIterations)"

        // The workers: rows made as they're first seen.
        let sorted = observer.sortedWorkers
        let order = sorted.map(\.station)
        if order != workerOrder {
            for row in workerRows.values { workers.remove(row.row) }
            workerRows = [:]
            for station in order {
                let row = MandelbrotWorkerRow()
                workerRows[station] = row
                workers.add(row.row)
            }
            workerOrder = order
        }
        noWorkers.isVisible = sorted.isEmpty
        let colours = workerColours
        for worker in sorted {
            workerRows[worker.station]?.update(worker, name: name(worker.station), colour: colours[worker.station] ?? 0x888888)
        }

        gaps.isVisible = observer.missedFrames > 0 || observer.malformed > 0
        missed.isVisible = observer.missedFrames > 0
        missed.title = "\(observer.missedFrames) frames went from the trace before they were read, so some tiles may be missing."
        malformed.isVisible = observer.malformed > 0
        malformed.title = "\(observer.malformed) frames on the demo's ports weren't its messages."
        picture.queueDraw()
    }

    private func name(_ station: UInt8) -> String {
        let node = session.project.nodes.first { $0.stationNumber == Int(station) }
        return node.map { "\($0.name) (\(station))" } ?? "Station \(station)"
    }
}

/// A worker in the Mandelbrot view's sidebar: its colour, name, state, and
/// what it's done.
@MainActor
final class MandelbrotWorkerRow {
    let row = ActionRow("")
    private var colour: UInt32 = 0
    private let swatch: DrawingArea
    private let state = Label("", style: "caption")
    private let stateIcon = Icon("media-playback-pause-symbolic", size: 12)

    init() {
        swatch = DrawingArea(width: 12, height: 12) { _, _, _ in }
        swatch.align(vertical: GTK_ALIGN_CENTER)
        swatch.setDraw { [self] cairo, width, height in
            cairo.color(hex: self.colour)
            cairo.roundedRectangle(0, 0, width, height, radius: 3)
            cairo.fill()
        }
        row.prefix(swatch)
        row.suffix(Box(.horizontal, spacing: 4) { stateIcon; state }.align(vertical: GTK_ALIGN_CENTER))
        adw_action_row_set_subtitle_lines(cast(row.widget), 0)
    }

    func update(_ worker: MandelbrotObserver.Worker, name: String, colour: UInt32) {
        if colour != self.colour {
            self.colour = colour
            swatch.queueDraw()
        }
        row.title = name
        var detail = "\(worker.tiles) tiles · \(worker.pixels) pixels · \(worker.iterations) iterations · \(worker.bytes) bytes"
        if worker.duplicates > 0 || worker.stale > 0 {
            detail += "\n\(worker.duplicates) duplicate, \(worker.stale) stale"
        }
        row.subtitle = detail
        let text: String = switch worker.state {
        case .idle: "Idle"
        case .computing: worker.current.map { "Computing tile \($0.tile)" } ?? "Computing"
        case .sending: worker.current.map { "Sending tile \($0.tile)" } ?? "Sending"
        case .unresponsive: "Unresponsive"
        }
        state.text = text
        let icon = switch worker.state {
        case .idle: "media-playback-pause-symbolic"
        case .computing: "emblem-system-symbolic"
        case .sending: "go-up-symbolic"
        case .unresponsive: "dialog-warning-symbolic"
        }
        // (An icon set again is laid out again, even if it's the same.)
        if stateIcon.name != icon { stateIcon.name = icon }
        for widget in [state, stateIcon] as [Widget] {
            widget.setStyle("warning", worker.state == .unresponsive)
            widget.setStyle("dim-label", worker.state != .unresponsive)
        }
    }
}
