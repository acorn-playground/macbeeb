import AppKit
import BeebPrint
import BeebROMs
import Observation
import UniformTypeIdentifiers

/// Every printer's jobs, newest first, kept in Application Support so they
/// survive quitting. Jobs arrive as the BBCs print them.
@MainActor
@Observable
final class PrintCentre {
    static let shared = PrintCentre()
    static let windowID = "print-centre"

    private(set) var jobs: [PrintJob] = []
    /// How jobs are put on paper. Remembered.
    var settings: PrintSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Self.settingsKey)
            }
        }
    }
    /// The job shown: a new job, as soon as it starts.
    var selection: UUID?
    /// Counts jobs started, so a window can come forward for a new one.
    private(set) var arrivals = 0

    /// The BBC's characters, for the dot-matrix style.
    let font = Array(BeebROMs.data(.os12)[0..<768])

    private static let settingsKey = "MacBeebPrintSettings"
    static let limit = 200

    private init() {
        settings = UserDefaults.standard.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(PrintSettings.self, from: $0) } ?? PrintSettings()
        load()
    }

    /// (A self-test's jobs go in a folder of their own, not the user's.)
    static let folder: URL = LaunchScreen.isSelfTest
        ? FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-print-jobs-\(UUID().uuidString)", isDirectory: true)
        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacBeeb/Print Jobs", isDirectory: true)

    /// Where a machine's printer sends its jobs (from any thread).
    nonisolated static func receiver() -> @Sendable (PrintJob) -> Void {
        { job in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PrintCentre.shared.update(job) }
            }
        }
    }

    func update(_ job: PrintJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
            arrivals += 1
            selection = job.id
        }
        if job.status != .printing {
            save(job)
        }
        if jobs.count > Self.limit {
            for old in jobs[Self.limit...] { remove(old.id) }
        }
    }

    func job(_ id: UUID?) -> PrintJob? {
        id.flatMap { id in jobs.first { $0.id == id } }
    }

    func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(id.uuidString).json"))
        if selection == id { selection = jobs.first?.id }
    }

    func removeAll() {
        for job in jobs { remove(job.id) }
    }

    private func save(_ job: PrintJob) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(job) {
            try? data.write(to: Self.folder.appendingPathComponent("\(job.id.uuidString).json"), options: .atomic)
        }
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        jobs = files.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PrintJob.self, from: $0) }
        }.sorted { $0.started > $1.started }
        selection = jobs.first?.id
    }

    // MARK: Exporting

    func printout(_ job: PrintJob) -> Printout {
        Printout(job.bytes, settings: settings)
    }

    func title(_ job: PrintJob) -> String {
        "\(job.printer) \(job.started.formatted(date: .abbreviated, time: .shortened))"
    }

    func exportPDF(_ job: PrintJob) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Print \(job.started.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try printout(job).pdf(font: font, title: title(job)).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func saveRawBytes(_ job: PrintJob) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = "Print job.prn"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(job.bytes).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Prints on the Mac's printer, through the standard print panel.
    func printOnMac(_ job: PrintJob) {
        let data = printout(job).pdf(font: font, title: title(job))
        guard let document = PDFDocumentView.document(data) else { return }
        let info = NSPrintInfo.shared
        info.paperSize = settings.paper.size
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: false)?.run()
    }
}
