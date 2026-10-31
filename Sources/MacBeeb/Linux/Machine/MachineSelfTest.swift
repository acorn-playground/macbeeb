import BeebCapture
import BeebHost
import CGtk
import Foundation

extension MachineController {
    /// `MacBeeb -MacBeebSelfTest /path/to/out.png`: types a command, then
    /// saves what the window is showing and quits, as on the Mac. For
    /// checking the app end to end without looking at it. Beside the
    /// screenshot: -display.png (the display as drawn, at twice the TV's
    /// size), -window.png (the whole window) and .txt (what ran).
    func runSelfTestIfRequested() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "MacBeebSelfTest") else { return }
        let disc = defaults.string(forKey: "MacBeebSelfTestDisc")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if let action = defaults.string(forKey: "MacBeebSelfTestOpen") {
                // `-MacBeebSelfTestOpen app.library` (or win.debugger, …):
                // runs an action, waits, and captures every window.
                await openAndCaptureWindows(action, path: path)
                return
            } else if defaults.double(forKey: "MacBeebSelfTestIdle") > 0 {
                // Waits while keys come from outside (the desktop's
                // remote-control API, say), then captures what they did.
                try? await Task.sleep(for: .seconds(defaults.double(forKey: "MacBeebSelfTestIdle")))
            } else if let disc {
                insertDisc(URL(fileURLWithPath: disc))
                try? await Task.sleep(for: .seconds(25))
            } else if let style = defaults.string(forKey: "MacBeebSelfTestDisplay").flatMap(DisplayStyle.init(rawValue:)) {
                // A busy picture, in a display style.
                displayStyle = style
                if let monitor = defaults.string(forKey: "MacBeebSelfTestMonitor").flatMap(Monitor.init(rawValue:)) {
                    self.monitor = monitor
                }
                host.send(.type("MODE 2\nFOR I%=0 TO 7:GCOL0,I%:RECTANGLE FILL I%*160,0,150,1023:NEXT\n"))
                try? await Task.sleep(for: .seconds(3))
            } else {
                host.send(.type("PRINT \"MACBEEB \";6*7\n"))
                try? await Task.sleep(for: .seconds(2))
            }
            let window = MachineWindow.existing(for: self)
            // `-MacBeebSelfTestMenu Machine`: the main menu, open at a
            // submenu (or its top), as -menu.png.
            if let submenu = defaults.string(forKey: "MacBeebSelfTestMenu"), let button = window?.menuButton {
                button.popup()
                try? await Task.sleep(for: .seconds(0.5))
                if let popover = gtk_menu_button_get_popover(cast(button.widget)) {
                    if !submenu.isEmpty, submenu != "top" {
                        gtk_popover_menu_set_menu_model(cast(popover), gtk_popover_menu_get_menu_model(cast(popover)))
                        _ = gtk_widget_activate_action_variant(WidgetPointer(OpaquePointer(popover)), "menu.open-submenu",
                                                               g_variant_new_string(submenu))
                        try? await Task.sleep(for: .seconds(0.5))
                    }
                    Capture.write(Widget(WidgetPointer(OpaquePointer(popover))),
                                  to: path.replacingOccurrences(of: ".png", with: "-menu.png"))
                }
                button.popdown()
            }
            // The display as drawn, at twice the TV's size.
            if let window {
                window.emulator.area.makeCurrent()
                let width = EmulatorHost.Frame.width * 2, height = EmulatorHost.Frame.height * 2
                if let pixels = window.emulator.renderer.renderPixels(width: width, height: height),
                   let png = PNGEncoder.encode(pixels: pixels, width: width, height: height) {
                    try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-display.png")))
                }
                // The whole window, header bar included.
                await Capture.writeAfterPaint(window.window, to: path.replacingOccurrences(of: ".png", with: "-window.png"))
            }
            let report = "frame=\(host.frame?.number ?? -1) cycles=\(host.cycles) audioQueued=\(host.audioRing.count)"
                + " renderer=\(window?.emulator.renderer.failure ?? "ok")\n"
            FileManager.default.createFile(atPath: path + ".txt", contents: Data(report.utf8))
            if let png = screenshotPNG() {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            Application.shared.quit()
        }
    }

    /// Runs `action` ("app.name" or "win.name", with a target after a colon:
    /// "app.guide:vscode"), waits (-MacBeebSelfTestWait seconds, default
    /// 2), then saves each window as path-window-N.png, their titles in
    /// path.txt, and quits.
    private func openAndCaptureWindows(_ action: String, path: String) async {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        let target = parts.count > 1 ? g_variant_new_string(parts[1]) : nil
        if parts[0].hasPrefix("app.") {
            g_action_group_activate_action(OpaquePointer(Application.shared.app), String(parts[0].dropFirst(4)), target)
        } else if let window = MachineWindow.existing(for: self) {
            gtk_widget_activate_action_variant(window.window.widget, parts[0], target)
        }
        let wait = UserDefaults.standard.double(forKey: "MacBeebSelfTestWait")
        try? await Task.sleep(for: .seconds(wait > 0 ? wait : 2))
        var report = ""
        for (index, window) in Application.shared.windows.enumerated() {
            let title = String(gBorrowed: gtk_window_get_title(window)) ?? ""
            let file = path.replacingOccurrences(of: ".png", with: "-window-\(index).png")
            await Capture.writeAfterPaint(Window.wrapping(window), to: file)
            report += "\(index): \(title) (\(gtk_widget_get_width(cast(window))) x \(gtk_widget_get_height(cast(window))))\n"
        }
        FileManager.default.createFile(atPath: path + ".txt", contents: Data(report.utf8))
        Application.shared.quit()
    }
}
