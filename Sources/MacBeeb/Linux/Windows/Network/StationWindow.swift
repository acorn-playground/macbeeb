import BeebNetwork
import CGtk
import Foundation

/// A network station in its own window: the same window a standalone
/// machine has, menus and all. Closing it leaves the station running. If
/// the station's switched off, or its network closes, its window goes; if
/// it starts again as a new machine (renumbered, say), the new one has the
/// window.
@MainActor
enum StationWindow {
    /// Windows watched, so a station's window is watched once.
    private static var watched: Set<ObjectIdentifier> = []

    static func show(network: URL, node: UUID) {
        guard let session = NetworkSession.existing(network), let controller = session.controllers[node] else {
            notRunning(node)
            return
        }
        Windows.existing("station-\(node)")?.close()
        let window = MachineWindow.show(controller)
        watch(window, session: session, node: node, controller: controller)
    }

    private static func watch(_ window: MachineWindow, session: NetworkSession, node: UUID, controller: MachineController) {
        let key = ObjectIdentifier(window)
        guard !watched.contains(key) else { return }
        watched.insert(key)
        let gtkWindow = window.window
        var open = true
        gtkWindow.onDestroy {
            open = false
            watched.remove(key)
        }
        gtkWindow.track { [gtkWindow] in
            let current = session.controllers[node]
            guard current !== controller else { return }
            // (After this change has settled.)
            MainLoop.after(0) {
                guard open else { return }
                gtkWindow.close()
                if current != nil { show(network: session.url, node: node) }
            }
        }
    }

    /// The machine's switched off, or its network isn't open.
    private static func notRunning(_ node: UUID) {
        Windows.show("station-\(node)") {
            let window = Window(title: "Not Running", width: 480, height: 360)
            window.minimumSize(width: 368, height: 288)
            window.content = ToolbarView(content: StatusPage(icon: "system-shutdown-symbolic", title: "Not Running",
                                                             description: "This machine is switched off, or its network isn’t open."))
                .top(HeaderBar())
            App.addStandardShortcuts(to: window)
            window.shortcut("<Alt>w", action: "window.close")
            return window
        }
    }
}
