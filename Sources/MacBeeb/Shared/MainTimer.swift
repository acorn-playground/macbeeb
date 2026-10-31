import Foundation

/// A repeating timer on the main thread. On the Mac it's Foundation's
/// Timer, scheduled in the run loop's default mode as always; on Linux,
/// where GLib's main loop runs rather than Foundation's, a dispatch timer on
/// the main queue (which GLib's loop serves).
@MainActor
final class MainTimer {
    #if os(macOS)
    nonisolated(unsafe) private var timer: Timer?
    #else
    nonisolated(unsafe) private var source: DispatchSourceTimer?
    #endif

    /// Calls `body` every `interval` seconds until invalidated.
    static func repeating(every interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> MainTimer {
        MainTimer(interval: interval, body)
    }

    private init(interval: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        #if os(macOS)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated(body)
        }
        #else
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        source.setEventHandler { MainActor.assumeIsolated(body) }
        source.resume()
        self.source = source
        #endif
    }

    func invalidate() {
        #if os(macOS)
        timer?.invalidate()
        timer = nil
        #else
        source?.cancel()
        source = nil
        #endif
    }

    deinit {
        #if os(macOS)
        timer?.invalidate()
        #else
        source?.cancel()
        #endif
    }
}
