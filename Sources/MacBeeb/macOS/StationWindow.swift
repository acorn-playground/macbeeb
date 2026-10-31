import BeebNetwork
import AppKit
import SwiftUI

/// A network station in its own window: the same window a standalone
/// machine has, menus and all. Closing it leaves the station running. Each
/// station's window is a window of its own, never a tab of another's
/// (which in full screen is what macOS would otherwise do, so that opening
/// a second station seemed to replace the first).
struct StationWindow: View {
    static let windowID = "station"

    /// Which station: its network's package and its node.
    struct Ref: Codable, Hashable {
        var network: URL
        var node: UUID
    }

    let ref: Ref?

    var body: some View {
        if let ref, let session = NetworkSession.existing(ref.network),
           let controller = session.controllers[ref.node] {
            MachineScreen(machine: controller)
                .id(ObjectIdentifier(controller))
                .background(NoWindowTabs())
        } else {
            ContentUnavailableView {
                Label("Not Running", systemImage: "power")
            } description: {
                Text("This machine is switched off, or its network isn’t open.")
            }
            .frame(minWidth: 368, minHeight: 288)
        }
    }
}

/// Keeps its window out of tabs: opened in full screen, another window is
/// a window (that can have a full screen of its own), not a tab.
struct NoWindowTabs: NSViewRepresentable {
    func makeNSView(context: Context) -> TabsOff { TabsOff() }
    func updateNSView(_ view: TabsOff, context: Context) {}

    final class TabsOff: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.tabbingMode = .disallowed
        }
    }
}
