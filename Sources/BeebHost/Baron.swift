// Runs Baron (github.com/waitingforvsync/baron; built into MacBeeb.app) to
// assemble source files to a disc image, with symbols and source lines for
// the debugger.

import BeebCore
import Foundation

public struct BaronBuild: Sendable {
    /// A DFS disc (.ssd) of the sections saved.
    public var disc: [UInt8]
    /// The files saved (the sections with a filename), in order.
    public var savedFiles: [String]
    /// The disc's *OPT 4 boot option (--opt).
    public var bootOption: Int
    public var symbols: SymbolTable
    /// Baron's messages (PRINT output, warnings).
    public var messages: String
}

public enum Baron {
    public enum BuildError: Error, CustomStringConvertible {
        case notFound
        case failed(String)
        case nothingSaved

        public var description: String {
            switch self {
            case .notFound:
                "Baron isn't installed: it comes with MacBeeb.app, or build it from github.com/waitingforvsync/baron and put it on your PATH"
            case .failed(let output):
                "Baron failed:\n" + output
            case .nothingSaved:
                "nothing is saved: give a SECTION a filename, e.g. SECTION Code, org=&2000, filename=\"GAME\""
            }
        }
    }

    /// The baron to use: `configured`, or the one beside this program (in
    /// MacBeeb.app), or on the PATH.
    public static func locate(_ configured: String? = nil) -> String? {
        let fm = FileManager.default
        if let configured, fm.isExecutableFile(atPath: configured) {
            return configured
        }
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "baron") {
            candidates.append(bundled.path)
        }
        let here = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        candidates.append((here as NSString).appendingPathComponent("baron"))
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { "\($0)/baron" }
        candidates += ["/opt/homebrew/bin/baron", "/usr/local/bin/baron"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Switches MacBeeb gives itself, which are dropped from `arguments`
    /// (with their values).
    static let ownSwitches: Set<String> = ["-o", "-p", "--symbols"]
    static let ownFlags: Set<String> = ["-v", "-vv", "--check", "--inf"]

    /// `arguments` without the switches that say where output goes.
    static func userArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < arguments.count {
            let argument = arguments[i]
            if ownSwitches.contains(argument) || argument.range(of: #"^-log[0-9]$"#, options: .regularExpression) != nil {
                i += 2
                continue
            }
            if !ownFlags.contains(argument) { result.append(argument) }
            i += 1
        }
        return result
    }

    /// Assembles `sources` (each on its own, as Baron does, with every
    /// saved section on one disc) with extra switches such as `-D DEBUG=1`
    /// or `--opt 3`. Baron runs in the first source's directory.
    public static func assemble(sources: [String], arguments: [String] = [], baron configured: String? = nil) throws(BuildError) -> BaronBuild {
        guard let baron = locate(configured) else { throw .notFound }
        guard !sources.isEmpty else { throw .failed("no source files") }
        let directory = ((sources[0] as NSString).standardizingPath as NSString).deletingLastPathComponent
        let sources = sources.map { path in
            ((path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)) as NSString).standardizingPath
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-baron-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let disc = temporary.appendingPathComponent("out.ssd").path
        let symbolsPath = temporary.appendingPathComponent("symbols.json").path
        let extra = userArguments(arguments)

        func run(_ arguments: [String]) throws(BuildError) -> (status: Int32, out: String, err: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: baron)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                throw .failed("couldn't run \(baron): \(error)")
            }
            // Read both at once, so neither pipe can fill and stall Baron.
            nonisolated(unsafe) var err = Data()
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) { err = stderr.fileHandleForReading.readDataToEndOfFile() }
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
        }

        let build = try run(extra + ["--symbols", symbolsPath, "-o", disc] + sources)
        guard build.status == 0 else {
            throw .failed((build.err + build.out).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let image = FileManager.default.contents(atPath: disc), let catalogue = try? DFSDisc(side: [UInt8](image)) else {
            throw .nothingSaved
        }
        let json = FileManager.default.contents(atPath: symbolsPath)
        let saved = json.flatMap { BaronSymbols($0, directory: directory) }?.savedFiles ?? []
        guard !saved.isEmpty else { throw .nothingSaved }

        // The listing of each file on its own, to line up with its source.
        var listings: [(source: String, listing: String)] = []
        for (index, source) in sources.enumerated() {
            let listed = try run(extra + ["-v", "-o", temporary.appendingPathComponent("listing\(index).ssd").path, source])
            listings.append((source, listed.out))
        }
        let symbols = SymbolTable.baron(symbols: json, listings: listings, directory: directory)
        return BaronBuild(disc: [UInt8](image), savedFiles: saved, bootOption: catalogue.bootOption, symbols: symbols,
                          messages: (build.err + build.out).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The file to *RUN when none is named: the first saved that isn't a
    /// !BOOT script.
    public static func runnable(_ build: BaronBuild) -> String? {
        build.savedFiles.first { name in
            // A directory prefix ("$.") doesn't matter.
            let bare = name.dropFirst().first == "." ? name.dropFirst(2) : Substring(name)
            return bare.uppercased() != "!BOOT"
        }
    }
}
