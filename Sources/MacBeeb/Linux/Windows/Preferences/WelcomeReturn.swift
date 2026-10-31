import CGtk
import Foundation

/// With the welcome screen as the opening screen, MacBeeb is a place to
/// come back to: closing the last other window brings the welcome screen
/// back, and closing that quits (as closing the last window does
/// otherwise). (The Mac's, which watches NSWindow closing.)
@MainActor
enum WelcomeReturn {
    static var applies: Bool { LaunchScreen.preference == .welcome && (!LaunchScreen.isSelfTest || testing) }

    /// `-MacBeebSelfTestWelcomeReturn YES`: a self-test that tries it.
    private static var testing: Bool { UserDefaults.standard.bool(forKey: "MacBeebSelfTestWelcomeReturn") }

    /// Called as the app starts. GTK quits when its last window goes; this
    /// holds it, to decide for itself: the welcome screen again, or quit.
    static func start() {
        guard !LaunchScreen.isSelfTest || testing else { return }
        let app = Application.shared!
        app.hold()
        app.object.onPointer("window-removed") { window in
            closed(wasWelcome: window != nil && window == WelcomeWindow.widget)
        }
        // (A window kept for later is hidden rather than removed.)
        app.object.onPointer("window-added") { window in
            guard let window else { return }
            GObjectRef(window).onChange("visible") {
                if gtk_widget_get_visible(cast(window.assumingMemoryBound(to: GtkWidget.self))) == 0 {
                    closed(wasWelcome: window == WelcomeWindow.widget)
                }
            }
        }
        // (Should the launch have opened nothing, as if a window had
        // closed.)
        MainLoop.after(3) { closed(wasWelcome: false) }
    }

    /// A window's gone: once any window it opened has appeared (as the
    /// welcome screen's buttons open one as it closes), if nothing's left,
    /// the welcome screen comes back, or if it was the welcome screen (or
    /// the welcome screen isn't the opening screen), MacBeeb quits.
    private static func closed(wasWelcome: Bool) {
        MainLoop.after(0.4) {
            let open = Application.shared.windows.contains { gtk_widget_get_visible(cast($0)) != 0 }
            guard !open else { return }
            if applies && !wasWelcome {
                WelcomeWindow.show()
            } else {
                Application.shared.quit()
            }
        }
    }
}
