import BeebAgentKit
import BeebCore
import BeebHost
import BeebNetwork
import BeebPrint
import Foundation

/// What agents see of the Network Studio: its stations, by name, and the
/// network tools. Calls come from the agent socket's thread; the studio's
/// state is the main thread's, so each one is answered there.
final class AppMachineDirectory: MachineDirectory, @unchecked Sendable {
    private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    func machines() -> [AgentMachine] {
        onMain {
            var list: [AgentMachine] = []
            if let standalone = MachineController.agentDefault {
                list.append(AgentMachine(id: "standalone", name: "Standalone window", network: nil, station: nil,
                                         role: "the default (no `machine`)", model: standalone.setup.summary, poweredOn: true))
            }
            for session in NetworkSession.open.values.sorted(by: { $0.project.name < $1.project.name }) {
                for node in session.project.stations {
                    list.append(AgentMachine(id: node.id.uuidString, name: node.name, network: session.project.name,
                                             station: node.stationNumber, role: node.kind.displayName,
                                             model: node.setup?.summary ?? "", poweredOn: session.isOn(node.id)))
                }
            }
            return list
        }
    }

    /// The station `name` names: its id, its name, "station N" or N, in
    /// any open network ("Network/name" picks the network).
    @MainActor
    private func find(_ name: String) -> Result<(NetworkSession, NetworkNode), AgentToolError> {
        var networkName: String?
        var key = name.trimmingCharacters(in: .whitespaces)
        if let slash = key.firstIndex(of: "/") {
            networkName = String(key[..<slash])
            key = String(key[key.index(after: slash)...])
        }
        let sessions = NetworkSession.open.values.filter { networkName == nil || $0.project.name.caseInsensitiveCompare(networkName!) == .orderedSame }
        let number = Int(key.lowercased().replacingOccurrences(of: "station", with: "").trimmingCharacters(in: .whitespaces))
        var found: [(NetworkSession, NetworkNode)] = []
        for session in sessions {
            for node in session.project.stations where node.id.uuidString.caseInsensitiveCompare(key) == .orderedSame
                || node.name.caseInsensitiveCompare(key) == .orderedSame || (number != nil && node.stationNumber == number) {
                found.append((session, node))
            }
        }
        if found.isEmpty {
            return .failure(AgentToolError(NetworkSession.open.isEmpty
                ? "not_found: no network is open (network_create or network_open)"
                : "not_found: no station \"\(name)\" (list_machines shows them)"))
        }
        if found.count > 1 {
            return .failure(AgentToolError("ambiguous_machine: \"\(name)\" could be " + found.map { "\($0.1.name) in \($0.0.project.name)" }.joined(separator: ", ")
                + "; use its id or \"Network/name\""))
        }
        return .success(found[0])
    }

    func context(for name: String) -> Result<MachineContext, AgentToolError> {
        onMain {
            if name.lowercased() == "standalone" {
                guard let host = MachineController.agentDefault?.host else {
                    return .failure(AgentToolError("not_found: there's no standalone machine window"))
                }
                return .success(host)
            }
            switch find(name) {
            case .failure(let error): return .failure(error)
            case .success(let (session, node)):
                guard let controller = session.controllers[node.id] else {
                    return .failure(AgentToolError("powered_off: \(node.name) is switched off (network_power action on)"))
                }
                return .success(controller.host)
            }
        }
    }

    func networkTool(_ name: String, arguments: JSONValue) -> ToolResult {
        // Opening a network opens a window, which needs SwiftUI's scene
        // machinery: done through a request the app's scene picks up.
        onMain { run(name, arguments) }
    }

    @MainActor
    private func run(_ name: String, _ arguments: JSONValue) -> ToolResult {
        switch name {
        case "list_machines":
            let list = machines()
            return .text(list.isEmpty ? "No machines: open a machine window or a network." : list.map(\.line).joined(separator: "\n"))
        case "network_status":
            let sessions = networks(arguments["network"]?.stringValue)
            guard !sessions.isEmpty else { return .error("not_found: no network is open") }
            return .text(sessions.map(status).joined(separator: "\n\n"))
        case "network_power":
            guard let machine = arguments["machine"]?.stringValue else { return .error("missing_argument: machine") }
            guard let action = arguments["action"]?.stringValue else { return .error("missing_argument: action") }
            switch find(machine) {
            case .failure(let error): return .error(error.message)
            case .success(let (session, node)):
                switch action {
                case "on": session.powerOn(node.id)
                case "off": session.powerOff(node.id)
                case "cold_boot": session.coldBoot(node.id)
                case "break": session.pressBreak(node.id)
                case "suspend": session.setSuspended(node.id, true)
                case "resume": session.setSuspended(node.id, false)
                case "start_server":
                    switch node.kind {
                    case .fileServer: session.startFileServer(node.id)
                    case .printServer: session.startPrinterServer(node.id)
                    default: return .error("invalid_value: \(node.name) isn't a server")
                    }
                default: return .error("invalid_value: action \(action)")
                }
                return .text("\(node.name): \(action) done. It's \(session.isOn(node.id) ? (session.isSuspended(node.id) ? "suspended" : "on") : "off").")
            }
        case "network_pause":
            let sessions = networks(arguments["network"]?.stringValue)
            guard !sessions.isEmpty else { return .error("not_found: no network is open") }
            let paused = arguments["paused"]?.boolValue ?? true
            for session in sessions { session.setPaused(paused) }
            return .text("\(sessions.map(\.project.name).joined(separator: ", ")): \(paused ? "paused" : "running")")
        case "network_trace":
            let sessions = networks(arguments["network"]?.stringValue)
            guard sessions.count == 1, let session = sessions.first else {
                return .error(sessions.isEmpty ? "not_found: no network is open" : "ambiguous_machine: name the network")
            }
            return .text(trace(session, arguments))
        case "print_jobs":
            let jobs = PrintCentre.shared.jobs
            return .text(jobs.isEmpty ? "Nothing printed yet." : jobs.map { job in
                "\(job.id.uuidString): \(job.printer), \(job.started.formatted(.iso8601)), \(job.status.rawValue), \(job.bytes.count) bytes, "
                    + "\(Printout(job.bytes, settings: PrintCentre.shared.settings).pageCount) page(s)"
            }.joined(separator: "\n"))
        case "print_job":
            guard let job = printJob(arguments) else { return .error("not_found: no print job with that id (print_jobs)") }
            let printout = Printout(job.bytes, settings: PrintCentre.shared.settings)
            var text = "\(job.printer), \(job.status.rawValue), \(job.bytes.count) bytes\n"
            for page in 0..<printout.pageCount {
                text += "--- page \(page + 1) ---\n" + printout.text(page: page) + "\n"
            }
            if !printout.unsupported.isEmpty {
                text += "Codes not drawn: " + printout.unsupported.map { "\($0.key) ×\($0.value)" }.sorted().joined(separator: ", ") + "\n"
            }
            text += "Bytes: " + job.bytes.prefix(4096).map { String(format: "%02X", $0) }.joined(separator: " ")
            return .text(text)
        case "export_print_job_pdf":
            guard let job = printJob(arguments) else { return .error("not_found: no print job with that id (print_jobs)") }
            let path = arguments["path"]?.stringValue
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("print-\(job.id.uuidString.prefix(8)).pdf").path
            let printout = Printout(job.bytes, settings: PrintCentre.shared.settings)
            do {
                try printout.pdf(font: PrintCentre.shared.font, title: PrintCentre.shared.title(job))
                    .write(to: URL(fileURLWithPath: path), options: .atomic)
                return .text("Saved \(printout.pageCount) page(s) to \(path)")
            } catch {
                return .error("write_failed: \(error.localizedDescription)")
            }
        case "network_create", "network_open":
            return open(name, arguments)
        default:
            return .error("unknown tool \(name)")
        }
    }

    @MainActor
    private func networks(_ name: String?) -> [NetworkSession] {
        NetworkSession.open.values.filter { name == nil || $0.project.name.caseInsensitiveCompare(name!) == .orderedSame }
            .sorted { $0.project.name < $1.project.name }
    }

    @MainActor
    private func printJob(_ arguments: JSONValue) -> PrintJob? {
        guard let id = arguments["id"]?.stringValue else { return nil }
        return PrintCentre.shared.jobs.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame || $0.id.uuidString.hasPrefix(id.uppercased()) }
    }

    @MainActor
    private func status(_ session: NetworkSession) -> String {
        let project = session.project
        var lines = ["network \"\(project.name)\" (\(session.url.path))",
                     "clock: " + (NetworkRuntime.clockRate(of: project).map { "\($0 / 1000) kbit/s" } ?? "none"),
                     "state: " + (session.paused ? "paused" : String(format: "running at %.0f%% of real time", session.status.speed * 100))]
        if !session.status.stoppedStations.isEmpty { lines.append("stopped in the debugger: \(session.status.stoppedStations.count)") }
        for problem in project.problems { lines.append("problem: " + problem.message) }
        for node in project.stations {
            var line = "  \(node.stationNumber.map { String($0) } ?? "-") \(node.name): \(node.kind.displayName), \(node.setup?.summary ?? ""), "
            line += session.isOn(node.id) ? (session.isSuspended(node.id) ? "suspended" : "on") : "off"
            if let number = node.stationNumber, let traffic = session.status.traffic[UInt8(clamping: number)] {
                line += "; sent \(traffic.frames) frames, \(traffic.bytes) bytes" + (traffic.collisions > 0 ? ", \(traffic.collisions) collided" : "")
            }
            if node.kind != .station, let console = session.controllers[node.id]?.consoleLine {
                line += "; console: \"\(console)\""
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    private func trace(_ session: NetworkSession, _ arguments: JSONValue) -> String {
        var frames = session.runtime.network.frames(after: arguments["after"]?.intValue)
        if let station = arguments["station"]?.intValue {
            frames = frames.filter { Int($0.transmitter) == station || $0.destinationStation.map(Int.init) == station }
        }
        if arguments["problems_only"]?.boolValue == true {
            frames = frames.filter { $0.status != .valid }
        }
        let limit = min(1000, max(1, arguments["limit"]?.intValue ?? 100))
        frames = Array(frames.suffix(limit))
        guard !frames.isEmpty else {
            return "No frames" + (arguments["after"] != nil ? " since then" : "") + " (\(session.runtime.network.frameCount) so far)."
        }
        return frames.map { frame in
            var line = String(format: "#%d %.4fs", frame.id, Double(frame.start) / 2_000_000)
            line += " \(frame.transmitter)->\(frame.destinationStation.map { String($0) } ?? "?") \(frame.kind.rawValue)"
            if let control = frame.control { line += String(format: " ctrl &%02X", control) }
            if let port = frame.port {
                line += String(format: " port &%02X", port) + (EconetFrame.portName(port).map { " (\($0))" } ?? "")
            }
            if let transaction = frame.transaction { line += " txn \(transaction)" }
            line += " \(frame.status.rawValue) [\(frame.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))]"
            return line
        }.joined(separator: "\n")
    }

    @MainActor
    private func open(_ name: String, _ arguments: JSONValue) -> ToolResult {
        let url: URL
        if name == "network_create" {
            let templates: [String: NetworkTemplate] = ["econet_demo": .econetDemo, "econet_times": .econetTimes, "elite_over_econet": .eliteOverEconet, "distributed_mandelbrot": .distributedMandelbrot,
                                                        "mandelbrot_in_colour": .mandelbrotInColour,
                                                        "two_bbcs": .twoBBCs,
                                                        "school_classroom": .schoolClassroom,
                                                        "bbc_and_master": .bbcAndMaster, "empty": .empty]
            guard let template = arguments["template"]?.stringValue.flatMap({ templates[$0] }) else {
                return .error("invalid_value: template must be one of \(templates.keys.sorted().joined(separator: ", "))")
            }
            let given = arguments["name"]?.stringValue
            // (An agent's networks are kept, in the networks folder.)
            url = RecentNetworks.newURL(named: given.flatMap { $0.isEmpty ? nil : $0 } ?? template.title, in: RecentNetworks.folder)
            do {
                try NetworkPackage.create(template, named: given, at: url)
            } catch {
                return .error("write_failed: \(error.localizedDescription)")
            }
        } else {
            guard let path = arguments["path"]?.stringValue else { return .error("missing_argument: path") }
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        do {
            let session = try NetworkSession.session(for: url)
            // And its window, for the person watching.
            NotificationCenter.default.post(name: NetworkStudioCommands.openRequest, object: url)
            return .text("Opened \"\(session.project.name)\" (\(url.path)):\n" + status(session))
        } catch {
            return .error("open_failed: \(error)")
        }
    }
}
