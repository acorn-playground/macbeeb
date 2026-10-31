import BeebHost
import Foundation
import Observation

/// Small live pictures of a network's machines, for the canvas. Only the
/// machines shown are sampled, a few times a second, and each picture is
/// made off the main thread at half size. The machines run whether or not
/// they're shown.
@MainActor
@Observable
final class ThumbnailCache {
    /// The latest picture of each machine shown.
    private(set) var images: [UUID: PlatformImage] = [:]
    @ObservationIgnored private var shown: [UUID: (host: EmulatorHost, count: Int)] = [:]
    @ObservationIgnored private var lastFrame: [UUID: Int] = [:]
    @ObservationIgnored private var timer: MainTimer?
    @ObservationIgnored private var working: Set<UUID> = []
    /// Pictures a second.
    static let rate = 10.0

    /// A view showing `host`'s picture has appeared.
    func show(_ id: UUID, host: EmulatorHost) {
        let count = (shown[id]?.host === host ? shown[id]?.count ?? 0 : 0) + 1
        shown[id] = (host, count)
        if timer == nil {
            timer = MainTimer.repeating(every: 1 / Self.rate) { [weak self] in
                MainActor.assumeIsolated { self?.sample() }
            }
        }
    }

    /// One of the views showing it has gone.
    func hide(_ id: UUID) {
        guard let entry = shown[id] else { return }
        if entry.count > 1 {
            shown[id] = (entry.host, entry.count - 1)
        } else {
            shown[id] = nil
            if shown.isEmpty {
                timer?.invalidate()
                timer = nil
            }
        }
    }

    /// Forgets a machine that's been switched off.
    func forget(_ id: UUID) {
        images[id] = nil
        lastFrame[id] = nil
    }

    private func sample() {
        for (id, entry) in shown where !working.contains(id) {
            guard let frame = entry.host.frame, frame.number != lastFrame[id] else { continue }
            lastFrame[id] = frame.number
            working.insert(id)
            DispatchQueue.global(qos: .utility).async {
                let image = Self.halfSize(frame.pixels)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.working.remove(id)
                        if self.shown[id] != nil, let image {
                            self.images[id] = image
                        }
                    }
                }
            }
        }
    }

    /// Every other pixel of every other line: the TV picture's lines are
    /// doubled already, so nothing's lost but horizontal detail.
    nonisolated static func halfSize(_ pixels: [UInt32]) -> PlatformImage? {
        let width = EmulatorHost.Frame.width / 2
        let height = EmulatorHost.Frame.height / 2
        guard pixels.count >= EmulatorHost.Frame.width * EmulatorHost.Frame.height else { return nil }
        var small = [UInt32](repeating: 0, count: width * height)
        pixels.withUnsafeBufferPointer { source in
            small.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let row = y * 2 * EmulatorHost.Frame.width
                    for x in 0..<width {
                        out[y * width + x] = source[row + x * 2]
                    }
                }
            }
        }
        return Platform.image(pixels: small, width: width, height: height)
    }
}
