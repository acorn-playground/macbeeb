import AppKit

/// Pictures of the app's windows, for documentation and the website.
///
/// Only with the MacBeebCaptureDirectory default set (e.g. as a launch
/// argument, `-MacBeebCaptureDirectory DIR`). Then other processes can post
/// distributed notifications, driving the machine through the agent socket
/// in between:
///
/// - `com.accidentalfish.macbeeb.capture`, with the notification's object a
///   name: writes NAME-WINDOW.png for each window (main, debugger), the
///   emulator's picture drawn in (a cached display leaves Metal out).
/// - `com.accidentalfish.macbeeb.showDebugger`: opens the debugger.
/// - `com.accidentalfish.macbeeb.showClassics`: opens the game library
///   (captured as NAME-classics.png).
@MainActor
enum DocumentationCapture {
    static let captureNotification = Notification.Name("com.accidentalfish.macbeeb.capture")
    static let showDebuggerNotification = Notification.Name("com.accidentalfish.macbeeb.showDebugger")
    static let showClassicsNotification = Notification.Name("com.accidentalfish.macbeeb.showClassics")

    static func start(for machine: MachineController) {
        guard let directory = UserDefaults.standard.string(forKey: "MacBeebCaptureDirectory") else { return }
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: captureNotification, object: nil, queue: .main) { notification in
            let name = notification.object as? String ?? "capture"
            Task { @MainActor in
                await captureWindows(machine: machine, to: URL(fileURLWithPath: directory), name: name)
            }
        }
        center.addObserver(forName: showDebuggerNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                machine.debuggerRequested = true
            }
        }
        center.addObserver(forName: showClassicsNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                machine.bookshelfRequested = true
            }
        }
    }

    /// Each window is made key first, so it looks active.
    static func captureWindows(machine: MachineController, to directory: URL, name: String) async {
        NSApp.activate()
        for window in NSApp.windows where window.isVisible {
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(400))
            guard let frameView = window.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { continue }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let suffix: String
            if let emulator = emulatorView(in: frameView) {
                suffix = "main"
                drawPicture(of: emulator, renderer: machine.renderer, into: rep, frameView: frameView)
            } else if window.title.hasPrefix("Debugger") {
                suffix = "debugger"
            } else if window.title == BookshelfView.title {
                suffix = "classics"
            } else {
                continue
            }
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    private static func emulatorView(in view: NSView) -> EmulatorNSView? {
        if let view = view as? EmulatorNSView { return view }
        for subview in view.subviews {
            if let found = emulatorView(in: subview) { return found }
        }
        return nil
    }

    /// Draws the emulator's picture, rendered as the view draws it, over
    /// the view's place in the cached window.
    private static func drawPicture(of view: EmulatorNSView, renderer: Renderer?, into rep: NSBitmapImageRep,
                                    frameView: NSView) {
        let scale = view.window?.backingScaleFactor ?? 2
        guard let renderer,
              let image = renderer.renderImage(width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale)),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let rect = frameView.convert(view.bounds, from: view)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSImage(cgImage: image, size: rect.size).draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }
}
