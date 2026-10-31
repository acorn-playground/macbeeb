import AppKit
import SwiftUI

/// Brings the Game Library to the front when a download arrives, opening it
/// if need be. On every window that can open it, so it works whichever are
/// open; opening an already-open window just raises it.
struct BringsLibraryForwardOnArrival: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: ClassicsLibrary.shared.arrivals) {
            openWindow(id: BookshelfView.windowID)
            Task { @MainActor in
                // The window may only just exist.
                try? await Task.sleep(for: .milliseconds(100))
                // The user's probably in their browser: activating may be
                // refused, so the window is also put in front regardless.
                NSApp.activate()
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(BookshelfView.windowID) == true }) {
                    window.orderFrontRegardless()
                    window.makeKey()
                }
            }
        }
    }
}

extension View {
    func bringsLibraryForwardOnArrival() -> some View {
        modifier(BringsLibraryForwardOnArrival())
    }
}
