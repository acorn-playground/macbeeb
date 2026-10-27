import AppKit
import BeebAgentKit
import BeebCapture
import BeebCore
import BeebNetwork
import SwiftUI

/// `MacBeeb -MacBeebNetworkSelfTest /path/to/out.png`: opens a School
/// Classroom network (in a temporary folder), runs a different program on
/// each machine, saves pictures of the studio window, and quits. For
/// checking the studio end to end without looking at it.
@MainActor
enum NetworkSelfTest {
    static var path: String? {
        UserDefaults.standard.string(forKey: "MacBeebNetworkSelfTest") ?? UserDefaults.standard.string(forKey: "MacBeebMCPSelfTest")
    }

    /// `-MacBeebMCPSelfTest /path/to/transcript.txt`: drives a network
    /// through the MCP tools, as an agent would (in-process, not over the
    /// socket), writes what they said, and quits.
    static func runMCPIfRequested() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: "MacBeebMCPSelfTest") else { return false }
        let tools = AgentTools(defaultContext: { nil }, directory: AppMachineDirectory())
        Thread.detachNewThread {
            var transcript = ""
            func call(_ name: String, _ arguments: JSONValue = [:]) -> String {
                let result = tools.call(name, arguments: arguments)
                let text = result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
                transcript += "> \(name) \(arguments)\n\(result.isError ? "ERROR " : "")\(text)\n\n"
                return text
            }
            _ = call("network_create", ["template": "school_classroom", "name": .string("MCP Test \(Int(Date().timeIntervalSince1970))")])
            _ = call("list_machines")
            // The file server starts itself.
            Thread.sleep(forTimeInterval: 15)
            _ = call("type_text", ["machine": "BBC 1", "text": "*NET\n10 PRINT \"AGENT\"\nSAVE \"AGENT\"\n"])
            Thread.sleep(forTimeInterval: 6)
            _ = call("type_text", ["machine": "1", "text": "*FX5,4\nVDU 2:PRINT \"PRINTED BY AN AGENT\":VDU 3\n"])
            Thread.sleep(forTimeInterval: 10)
            _ = call("network_status")
            _ = call("network_trace", ["limit": 12])
            _ = call("econet_status", ["machine": "File Server"])
            _ = call("screenshot", ["machine": "BBC 9"])
            let jobs = call("print_jobs")
            if let id = jobs.split(separator: ":").first.map(String.init) {
                _ = call("print_job", ["id": .string(id)])
                _ = call("export_print_job_pdf", ["id": .string(id)])
            }
            _ = call("network_power", ["machine": "File Server", "action": "off"])
            _ = call("type_text", ["machine": "BBC 2", "text": "*NET\n*CAT\n"])
            Thread.sleep(forTimeInterval: 8)
            _ = call("read_screen_text", ["machine": "BBC 2"])
            try? transcript.write(toFile: path, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    /// Shows the studio in a window of its own (no scene needed, so it
    /// works whatever windows the app restores).
    static func runIfRequested() {
        guard let path else { return }
        if let template = UserDefaults.standard.string(forKey: "MacBeebNetworkSelfTestTemplate"),
           template == "internetHost" || template == "internetGuest" {
            runInternet(path, host: template == "internetHost")
            return
        }
        if UserDefaults.standard.string(forKey: "MacBeebNetworkSelfTestTemplate") == "rename" {
            // A network renamed: its file follows, discs and all.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-rename-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("Econet Demo.\(NetworkPackage.fileExtension)")
            try? NetworkPackage.create(.econetDemo, at: url)
            var report = ""
            if let session = try? NetworkSession.session(for: url) {
                session.update { $0.name = "Renamed: Classroom" }
                session.renameFileToMatch()
                report += "New file: \(session.url.lastPathComponent)\n"
                report += "Old gone: \(!FileManager.default.fileExists(atPath: url.path)), new there: \(FileManager.default.fileExists(atPath: session.url.path))\n"
                report += "Found by old address: \(NetworkSession.existing(url) === session)\n"
                report += "Reopens: \((try? NetworkPackage.load(from: session.url))?.name ?? "no")\n"
                session.close()
            }
            // A new network, kept: named and moved, no longer a draft.
            let kept = folder.appendingPathComponent("Kept", isDirectory: true)
            if let draft = try? NetworkStudioCommands.createDraft(.twoBBCs), let session = try? NetworkSession.session(for: draft) {
                report += "Draft: \(session.project.isDraft), in drafts folder: \(draft.path.contains("Draft Networks"))\n"
                try? session.keep(as: "My Two BBCs", in: kept)
                report += "Kept as: \(session.url.path.replacingOccurrences(of: folder.path, with: "")), draft: \(session.project.isDraft), draft file gone: \(!FileManager.default.fileExists(atPath: draft.path))\n"
                session.close()
            }
            // Another, deleted.
            if let draft = try? NetworkStudioCommands.createDraft(.twoBBCs), let session = try? NetworkSession.session(for: draft) {
                Task { @MainActor in
                    // A running machine renumbered: a new machine, at its new number.
                    let demo = folder.appendingPathComponent("Renumber.\(NetworkPackage.fileExtension)")
                    if (try? NetworkPackage.create(.twoBBCs, at: demo)) != nil, let other = try? NetworkSession.session(for: demo),
                       let node = other.project.stations.first, other.controllers[node.id] != nil {
                        try? await Task.sleep(for: .seconds(1))
                        let problem = other.renumber(node.id, to: 42)
                        try? await Task.sleep(for: .seconds(1))
                        let station = try? await other.controllers[node.id]?.host.performAsync { $0.machine.econet?.station }
                        report += "Renumbered running \(node.name): \(problem ?? "ok"), its interface now station \(station.flatMap { $0 }.map(String.init) ?? "?")\n"
                        other.close()
                    }
                    await session.discard()
                    session.close()
                    report += "Deleted: gone \(!FileManager.default.fileExists(atPath: draft.path)), in recents \(RecentNetworks.shared.urls.contains(draft.standardizedFileURL))\n"
                    try? report.write(toFile: path, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
                return
            }
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }
        if UserDefaults.standard.string(forKey: "MacBeebNetworkSelfTestTemplate") == "welcome" {
            // The welcome screen, captured.
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1060, height: 800),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentViewController = NSHostingController(rootView: WelcomeView())
            window.setContentSize(window.contentViewController!.view.fittingSize)
            window.orderBack(nil)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                capture(window, to: path)
                NSApp.terminate(nil)
            }
            return
        }
        if UserDefaults.standard.string(forKey: "MacBeebNetworkSelfTestTemplate") == "hardware" {
            runHardware(path)
            return
        }
        if UserDefaults.standard.string(forKey: "MacBeebNetworkSelfTestTemplate") == "stationWindows" {
            runStationWindows(path)
            return
        }
        if UserDefaults.standard.string(forKey: "MacBeebNetworkSelfTestTemplate") == NetworkTemplate.eliteOverEconet.rawValue {
            runElite(path)
            return
        }
        if UserDefaults.standard.string(forKey: "MacBeebNetworkSelfTestTemplate") == NetworkTemplate.econetTimes.rawValue {
            runEconetTimes(path)
            return
        }
        if let name = UserDefaults.standard.string(forKey: "MacBeebNetworkSelfTestTemplate"),
           let template = NetworkTemplate(rawValue: name), template == .distributedMandelbrot || template == .mandelbrotInColour {
            runMandelbrot(path, template: template)
            return
        }
        NSLog("MacBeeb: network self-test starting")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-network-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Econet Demo.\(NetworkPackage.fileExtension)")
        try? NetworkPackage.create(.econetDemo, at: url)
        guard let session = try? NetworkSession.session(for: url) else {
            NSLog("MacBeeb: network self-test: can't open the network")
            NSApp.terminate(nil)
            return
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: NetworkStudioView(session: session).frame(width: 1180, height: 780))
        window.contentViewController = hosting
        window.title = session.project.name
        window.orderBack(nil)
        Task { @MainActor in
            // The file server starts itself; give it time.
            try? await Task.sleep(for: .seconds(10))
            let programs = [
                "*NET\n10 PRINT \"SAVED ON THE FILE SERVER\"\nSAVE \"HELLO\"\n*CAT\n",
                "MODE 2:FOR I%=0 TO 7:GCOL0,I%:X%=I%*160:MOVE X%,0:MOVE X%,1023:PLOT 85,X%+159,0:PLOT 85,X%+159,1023:NEXT\n",
                "MODE 1:FOR I%=0 TO 300 STEP 10:GCOL0,1+I% MOD 3:MOVE 640,512:DRAW 640+I%*COS(I%),512+I%*SIN(I%):NEXT\n",
                "*FX5,4\nVDU 2:PRINT \"HELLO FROM STATION 3, OVER ECONET\":FOR I%=1 TO 12:PRINT \"LINE \";I%:NEXT:VDU 3\n",
                "10 PRINT \"STATION 4 \";:GOTO 10\nRUN\n",
            ]
            for (node, program) in zip(session.project.stations.filter { $0.kind == .station && $0.bootsDisc != true }, programs) {
                session.controllers[node.id]?.host.send(.type(program))
            }
            try? await Task.sleep(for: .seconds(8))
            // Station 2 runs what station 1 saved.
            if let second = session.project.stations.filter({ $0.kind == .station && $0.bootsDisc != true }).dropFirst().first {
                session.controllers[second.id]?.host.send(.type("*NET\nCHAIN \"HELLO\"\n"))
            }
            try? await Task.sleep(for: .seconds(4))
            capture(window, to: path)
            session.selection = [session.project.stations[0].id]
            try? await Task.sleep(for: .seconds(1))
            capture(window, to: path.replacingOccurrences(of: ".png", with: "-selected.png"))
            // The Print Centre, with what station 3 printed.
            try? await Task.sleep(for: .seconds(8))
            let prints = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 760),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            prints.contentViewController = NSHostingController(rootView: PrintCentreWindow().frame(width: 1000, height: 760))
            prints.orderBack(nil)
            try? await Task.sleep(for: .seconds(2))
            capture(prints, to: path.replacingOccurrences(of: ".png", with: "-print.png"))
            NSApp.terminate(nil)
        }
    }

    /// With `-MacBeebNetworkSelfTestTemplate distributedMandelbrot` (or
    /// mandelbrotInColour, with *MANDEL2): opens the Mandelbrot network, waits for the workers to boot
    /// from the network, types *CLUSTER and *MANDEL on the Guide as its
    /// screen says, waits for the picture, and saves the canvas, the
    /// Mandelbrot view and every machine's screen text (path.txt).
    static func runMandelbrot(_ path: String, template: NetworkTemplate) {
        NSLog("MacBeeb: Mandelbrot self-test starting")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-network-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(template.title).\(NetworkPackage.fileExtension)")
        guard (try? NetworkPackage.create(template, at: url)) != nil,
              let session = try? NetworkSession.session(for: url) else {
            NSLog("MacBeeb: Mandelbrot self-test: can't open the network")
            NSApp.terminate(nil)
            return
        }
        func window(_ mode: NetworkStudioView.Mode) -> NSWindow {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 820),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.contentViewController = NSHostingController(rootView: NetworkStudioView(session: session, mode: mode)
                .frame(width: 1400, height: 820))
            window.orderBack(nil)
            return window
        }
        let canvas = window(.canvas)
        let view = window(.mandelbrot)
        let stations = session.project.stations.filter { $0.kind == .station }
        func screens() async -> [(String, String)] {
            var result: [(String, String)] = []
            for node in stations {
                let text = (try? await session.controllers[node.id]?.host.performAsync { $0.machine.screenText().joined(separator: "\n") }) ?? nil
                result.append((node.name, text ?? "(off)"))
            }
            return result
        }
        func waitFor(_ seconds: Int, _ done: ([(String, String)]) -> Bool) async -> Bool {
            for _ in 0..<seconds {
                if done(await screens()) { return true }
                try? await Task.sleep(for: .seconds(1))
            }
            return false
        }
        Task { @MainActor in
            var report = ""
            let workers = stations.filter { $0.bootsDisc != true }.map(\.name)
            let booted = await waitFor(120) { screens in
                screens.filter { workers.contains($0.0) }.allSatisfy { $0.1.contains("BASIC") }
            }
            // (And the Guide logged on, once the server's up.)
            try? await Task.sleep(for: .seconds(15))
            report += "Workers at BASIC: \(booted)\n"
            guard let guide = stations.first(where: { $0.bootsDisc == true }), let controller = session.controllers[guide.id] else { return }
            controller.host.send(.type("*CLUSTER\n"))
            let launched = await waitFor(90) { $0.first { $0.0 == guide.name }?.1.contains("failed.") == true }
            report += "CLUSTER finished: \(launched)\n"
            capture(canvas, to: path.replacingOccurrences(of: ".png", with: "-cluster.png"))
            controller.host.send(.type(template == .mandelbrotInColour ? "*MANDEL2\n" : "*MANDEL\n"))
            let start = Date()
            let complete = await waitFor(240) { screens in
                screens.filter { workers.contains($0.0) }.allSatisfy { $0.1.contains("run complete") }
            }
            report += "Render complete: \(complete) after \(Int(Date().timeIntervalSince(start)))s wall\n"
            try? await Task.sleep(for: .seconds(1))
            capture(canvas, to: path)
            capture(view, to: path.replacingOccurrences(of: ".png", with: "-mandelbrot.png"))
            // The Focus view: the Guide large and selected, every machine
            // down the left.
            session.update { $0.workspace.focus = guide.id }
            session.selection = [guide.id]
            let focus = window(.focus)
            try? await Task.sleep(for: .seconds(2))
            capture(focus, to: path.replacingOccurrences(of: ".png", with: "-focus.png"))
            let traffic = window(.traffic)
            try? await Task.sleep(for: .seconds(2))
            capture(traffic, to: path.replacingOccurrences(of: ".png", with: "-traffic.png"))
            for (name, text) in await screens() {
                report += "\n== \(name)\n\(text)\n"
            }
            try? report.write(toFile: path.replacingOccurrences(of: ".png", with: ".txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// With `-MacBeebNetworkSelfTestTemplate eliteOverEconet`: opens the
    /// Elite over Econet network and leaves it to set itself up, until its
    /// three commanders are on the scoreboard; then saves the canvas, the
    /// Focus view of the scoreboard, and every machine's screen (path.txt).
    static func runElite(_ path: String) {
        NSLog("MacBeeb: Elite self-test starting")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-network-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Elite over Econet.\(NetworkPackage.fileExtension)")
        guard (try? NetworkPackage.create(.eliteOverEconet, at: url)) != nil,
              let session = try? NetworkSession.session(for: url) else {
            NSLog("MacBeeb: Elite self-test: can't open the network")
            NSApp.terminate(nil)
            return
        }
        func window(_ mode: NetworkStudioView.Mode) -> NSWindow {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 820),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.contentViewController = NSHostingController(rootView: NetworkStudioView(session: session, mode: mode)
                .frame(width: 1400, height: 820))
            window.orderBack(nil)
            return window
        }
        let canvas = window(.canvas)
        Task { @MainActor in
            let start = Date()
            var report = ""
            guard let scoreboard = session.project.stations.first(where: { $0.name == EliteOverEconet.scoreboardName }) else { return }
            let commanders = session.project.nodes.compactMap { $0.startupScript.flatMap(EliteOverEconet.commander(in:)) }
            var board = ""
            // -MacBeebSelfTestFilm N: station N's screen every second.
            let film = UserDefaults.standard.integer(forKey: "MacBeebSelfTestFilm")
            for second in 0..<400 {
                if film != 0, let node = session.project.stations.first(where: { $0.stationNumber == film }),
                   let frame = session.controllers[node.id]?.host.frame,
                   let png = Screenshot.png(pixels: frame.pixels, width: TVOutput.width, height: TVOutput.height) {
                    try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: String(format: "-film-%03d.png", second))))
                }
                board = (try? await session.controllers[scoreboard.id]?.host.performAsync { $0.machine.screenText().joined(separator: "\n") })
                    .flatMap { $0 } ?? ""
                if commanders.allSatisfy(board.contains) { break }
                try? await Task.sleep(for: .seconds(1))
            }
            report += "Commanders \(commanders) on the scoreboard: \(commanders.allSatisfy(board.contains)) after \(Int(Date().timeIntervalSince(start)))s wall\n\n\(board)\n"
            capture(canvas, to: path)
            session.update { $0.workspace.focus = scoreboard.id }
            let focus = window(.focus)
            try? await Task.sleep(for: .seconds(2))
            capture(focus, to: path.replacingOccurrences(of: ".png", with: "-focus.png"))
            for node in session.project.stations {
                let text = (try? await session.controllers[node.id]?.host.performAsync { $0.machine.screenText().joined(separator: "\n") }) ?? nil
                report += "\n== \(node.name)\n\(text ?? "(off)")\n"
                if let frame = session.controllers[node.id]?.host.frame,
                   let png = Screenshot.png(pixels: frame.pixels, width: TVOutput.width, height: TVOutput.height) {
                    try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(node.stationNumber ?? 0).png")))
                }
            }
            try? report.write(toFile: path.replacingOccurrences(of: ".png", with: ".txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// With `-MacBeebNetworkSelfTestTemplate stationWindows`: opens a
    /// window for each of a network's stations, one after another, as the
    /// studio does, and writes which windows there are then.
    static func runStationWindows(_ path: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-network-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Station Windows.\(NetworkPackage.fileExtension)")
        guard (try? NetworkPackage.create(.schoolClassroom, at: url)) != nil, let session = try? NetworkSession.session(for: url) else {
            NSApp.terminate(nil)
            return
        }
        let refs = session.project.stations.filter { $0.kind == .station }.prefix(3).map { StationWindow.Ref(network: session.url, node: $0.id) }
        let opener = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        opener.contentViewController = NSHostingController(rootView: StationWindowOpener(refs: Array(refs)))
        opener.orderBack(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            let report = NSApp.windows.filter(\.isVisible).map { "\($0.identifier?.rawValue ?? "-") \($0.title) (tabs: \($0.tabbedWindows?.count ?? 0))" }.joined(separator: "\n")
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    static func capture(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("MacBeeb: network self-test: no window")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Opens station windows one at a time, as clicking each in turn would.
private struct StationWindowOpener: View {
    let refs: [StationWindow.Ref]
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.task {
            for ref in refs {
                openWindow(id: StationWindow.windowID, value: ref)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
