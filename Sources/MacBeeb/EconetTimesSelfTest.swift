import AppKit
import BeebNetwork
import SwiftUI

extension NetworkSelfTest {
    /// `-MacBeebNetworkSelfTestTemplate econetTimes`: the newsroom, as a
    /// visitor would use it. Two reporters file their desks' own stories,
    /// the editor prints the paper, and the canvas and the Print Centre are
    /// captured (path-canvas.png; path-proof.png and path-print.png, the
    /// Print Centre open as a reporter's proof and then the paper arrive), with what the machines
    /// showed in path.txt.
    static func runEconetTimes(_ path: String) {
        NSLog("MacBeeb: Econet Times self-test starting")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-times-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("The Econet Times.\(NetworkPackage.fileExtension)")
        var report = ""
        func finish() {
            try? report.write(toFile: path.replacingOccurrences(of: ".png", with: ".txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        guard (try? NetworkPackage.create(.econetTimes, at: url)) != nil, let session = try? NetworkSession.session(for: url) else {
            return finish()
        }
        let canvas = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1300, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        canvas.isReleasedWhenClosed = false
        canvas.contentViewController = NSHostingController(rootView: NetworkStudioView(session: session, mode: .canvas).frame(width: 1300, height: 800))
        canvas.orderBack(nil)
        func screen(_ id: UUID) async -> String {
            (try? await session.controllers[id]?.host.performAsync { $0.machine.screenText().joined(separator: "\n") }) ?? "(off)"
        }
        func wait(_ id: UUID, for text: String, seconds: Int) async -> Bool {
            for _ in 0..<seconds * 2 {
                if await screen(id).contains(text) { return true }
                try? await Task.sleep(for: .milliseconds(500))
            }
            return false
        }
        Task { @MainActor in
            let stations = session.project.stations.filter { $0.kind == .station }
            guard let editor = stations.first(where: { $0.stationNumber == 1 }) else { return finish() }
            let reporters = stations.filter { $0.stationNumber != 1 }
            report += "Editor's board: \(await wait(editor.id, for: "Nothing to print yet", seconds: 90))\n"
            // Two reporters file their desks' own stories: News and Weather.
            for (reporter, desk) in zip(reporters, ["1", "3"]) {
                report += "\(reporter.name) at its desk: \(await wait(reporter.id, for: "Which desk", seconds: 60))\n"
                session.controllers[reporter.id]?.host.send(.type(desk))
                try? await Task.sleep(for: .seconds(2))
                session.controllers[reporter.id]?.host.send(.type("\n\(reporter.name.uppercased())\n\n"))
                report += "\(reporter.name) filed: \(await wait(reporter.id, for: "Filed!", seconds: 60))\n"
            }
            // The Print Centre's open as the jobs arrive: a reporter's proof,
            // then the paper, which it should end up showing.
            let prints = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 900),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            prints.isReleasedWhenClosed = false
            prints.contentViewController = NSHostingController(rootView: PrintCentreWindow().frame(width: 1000, height: 900))
            prints.orderBack(nil)
            if let first = reporters.first {
                session.controllers[first.id]?.host.send(.type("P"))
                report += "Proof printed: \(await wait(first.id, for: "Printed:", seconds: 60))\n"
                try? await Task.sleep(for: .seconds(4))
                capture(prints, to: path.replacingOccurrences(of: ".png", with: "-proof.png"))
            }
            report += "On the board: \(await wait(editor.id, for: "Fine, With Scattered", seconds: 30))\n"
            session.controllers[editor.id]?.host.send(.type("P"))
            report += "Printed: \(await wait(editor.id, for: "Printed:", seconds: 120))\n"
            try? await Task.sleep(for: .seconds(5))
            report += "Print jobs: \(PrintCentre.shared.jobs.map { "\($0.printer), \($0.bytes.count) bytes" })\n"
            report += "Showing the newest job: \(PrintCentre.shared.selection == PrintCentre.shared.jobs.first?.id)\n"
            capture(canvas, to: path.replacingOccurrences(of: ".png", with: "-canvas.png"))
            capture(prints, to: path.replacingOccurrences(of: ".png", with: "-print.png"))
            for station in stations {
                report += "\n== \(station.name)\n\(await screen(station.id))\n"
            }
            finish()
        }
    }
}
