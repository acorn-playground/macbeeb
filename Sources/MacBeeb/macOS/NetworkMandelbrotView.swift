import BeebCore
import BeebHost
import BeebNetwork
import CoreGraphics
import SwiftUI

/// Follows the network's trace for the Distributed Mandelbrot demo, for
/// the studio's Mandelbrot view. It reads the frames from when it's first
/// shown until the studio closes, so switching views doesn't lose a
/// render. It only watches: what's drawn is what the workers sent.
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

    @ObservationIgnored private var picture: (key: PictureKey, image: CGImage)?

    private struct PictureKey: Equatable {
        var run: UInt32?
        var accepted: Int
        var authentic: Bool
        var max: Int
    }

    /// The accepted tiles' counts as colours; missing pixels are clear.
    func image(authentic: Bool) -> CGImage? {
        let key = PictureKey(run: observer.runId, accepted: observer.tilesCompleted, authentic: authentic, max: observer.maxIterations)
        if let picture, picture.key == key { return picture.image }
        let width = MandelbrotProtocol.imageWidth, height = MandelbrotProtocol.imageHeight
        let observer = self.observer
        let max = observer.maxIterations
        let table = (0 ... 255).map { n in authentic ? Self.mode5(n, max: max) : Self.gradient(n, max: max) }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0 ..< width * height where observer.covered[i] {
            let (r, g, b) = table[Int(observer.image[i])]
            pixels[i * 4] = r
            pixels[i * 4 + 1] = g
            pixels[i * 4 + 2] = b
            pixels[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
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
struct NetworkMandelbrotView: View {
    @Bindable var session: NetworkSession
    let feed: MandelbrotFeed
    @AppStorage("mandelbrotAuthenticPalette") private var authentic = true
    @AppStorage("mandelbrotShowsInFlight") private var showsInFlight = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if feed.observer.isEmpty {
                ContentUnavailableView {
                    Label("No Mandelbrot Traffic Yet", systemImage: "square.grid.3x3.square")
                } description: {
                    Text("When the Distributed Mandelbrot demo runs on this network, its picture builds up here from the frames on the line: run MANDEL on one machine, and CLUSTER to start the workers.")
                }
            } else {
                HSplitView {
                    picture
                        .frame(minWidth: 320)
                    sidebar
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                }
            }
        }
        .onAppear { feed.start(session) }
        .onDisappear { feed.hidden() }
    }

    private var observer: MandelbrotObserver { feed.observer }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Toggle("Authentic MODE 5 palette", isOn: $authentic)
                .help("The coordinator's own four colours, or a smoother gradient from the same counts")
            Toggle("Tiles in flight", isOn: $showsInFlight)
                .help("Outline the tiles given out and not yet accepted, in their worker's colour")
            Spacer()
            if !observer.isEmpty {
                Text(progressText)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button { feed.reset() } label: { Label("Clear", systemImage: "trash") }
                .disabled(observer.isEmpty)
                .help("Forget what's been seen, and follow from here")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var progressText: String {
        var text = "\(observer.tilesCompleted) of \(MandelbrotProtocol.tileCount) tiles"
        if let seconds = observer.elapsedSeconds { text += String(format: " · %.1f s", seconds) }
        if observer.completeSeen { text += " · Complete" }
        return text
    }

    // MARK: Picture

    /// MODE 5's pixels are twice as wide as they're tall.
    static let aspect = Double(MandelbrotProtocol.imageWidth * 2) / Double(MandelbrotProtocol.imageHeight)

    private var picture: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            ZStack {
                Rectangle().fill(Color(white: 0.12))
                if let image = feed.image(authentic: authentic) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                }
                if showsInFlight {
                    inFlight
                }
            }
            .aspectRatio(Self.aspect, contentMode: .fit)
            .padding(12)
        }
    }

    private var inFlight: some View {
        let assignments = observer.inFlight
        let colours = workerColours
        return Canvas { context, size in
            let sx = size.width / Double(MandelbrotProtocol.imageWidth)
            let sy = size.height / Double(MandelbrotProtocol.imageHeight)
            for assignment in assignments {
                let rect = CGRect(x: Double(assignment.x) * sx, y: Double(assignment.y) * sy,
                                  width: Double(assignment.width) * sx, height: Double(assignment.height) * sy)
                let colour = colours[assignment.station] ?? .white
                context.fill(Path(rect), with: .color(colour.opacity(0.25)))
                context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(colour), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }

    private static let palette: [Color] = [.orange, .green, .pink, .purple, .teal, .red, .yellow, .mint, .indigo, .brown]

    /// Each worker's colour, by station, in order.
    private var workerColours: [UInt8: Color] {
        Dictionary(uniqueKeysWithValues: observer.sortedWorkers.enumerated().map { ($1.station, Self.palette[$0 % Self.palette.count]) })
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorSection("Render") {
                    ProgressView(value: Double(observer.tilesCompleted), total: Double(MandelbrotProtocol.tileCount))
                    LabeledContent("Accepted", value: "\(observer.tilesCompleted) of \(MandelbrotProtocol.tileCount) tiles")
                    LabeledContent("Received", value: "\(observer.received.count) result\(observer.received.count == 1 ? "" : "s")")
                    LabeledContent("In flight", value: "\(observer.inFlight.count)")
                    if let seconds = observer.elapsedSeconds {
                        LabeledContent("Time", value: String(format: "%.1f s emulated", seconds) + (observer.completeSeen ? ", complete" : ""))
                    }
                    if let coordinator = observer.coordinator {
                        LabeledContent("Coordinator", value: name(coordinator))
                    }
                    if let run = observer.runId {
                        LabeledContent("Run", value: String(format: "&%08X", run))
                    }
                    LabeledContent("Iterations", value: "At most \(observer.maxIterations)")
                }
                InspectorSection("Workers") {
                    if observer.workers.isEmpty {
                        Text("None seen yet").foregroundStyle(.secondary)
                    }
                    ForEach(observer.sortedWorkers) { worker in
                        workerRow(worker)
                    }
                }
                if observer.missedFrames > 0 || observer.malformed > 0 {
                    InspectorSection("Gaps") {
                        if observer.missedFrames > 0 {
                            Label("\(observer.missedFrames) frames went from the trace before they were read, so some tiles may be missing.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if observer.malformed > 0 {
                            Label("\(observer.malformed) frames on the demo's ports weren't its messages.", systemImage: "exclamationmark.triangle")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("Drawn only from the counts the workers sent, for the tiles the coordinator accepted. Nothing is worked out here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    private func workerRow(_ worker: MandelbrotObserver.Worker) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(workerColours[worker.station] ?? .gray)
                    .frame(width: 12, height: 12)
                Text(name(worker.station))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Label(stateText(worker), systemImage: stateSymbol(worker.state))
                    .font(.caption)
                    .foregroundStyle(worker.state == .unresponsive ? Color.orange : .secondary)
            }
            Text("\(worker.tiles) tiles · \(worker.pixels) pixels · \(worker.iterations) iterations · \(worker.bytes) bytes")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if worker.duplicates > 0 || worker.stale > 0 {
                Text("\(worker.duplicates) duplicate, \(worker.stale) stale")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func stateText(_ worker: MandelbrotObserver.Worker) -> String {
        switch worker.state {
        case .idle: return "Idle"
        case .computing: return worker.current.map { "Computing tile \($0.tile)" } ?? "Computing"
        case .sending: return worker.current.map { "Sending tile \($0.tile)" } ?? "Sending"
        case .unresponsive: return "Unresponsive"
        }
    }

    private func stateSymbol(_ state: MandelbrotObserver.Worker.State) -> String {
        switch state {
        case .idle: "pause.circle"
        case .computing: "gearshape"
        case .sending: "arrow.up.circle"
        case .unresponsive: "exclamationmark.triangle"
        }
    }

    private func name(_ station: UInt8) -> String {
        let node = session.project.nodes.first { $0.stationNumber == Int(station) }
        return node.map { "\($0.name) (\(station))" } ?? "Station \(station)"
    }
}
