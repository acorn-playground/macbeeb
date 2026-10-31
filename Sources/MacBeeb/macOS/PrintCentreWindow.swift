import AppKit
import BeebPrint
import PDFKit
import SwiftUI

/// Window > Print Centre: every job the BBCs have printed, on paper as the
/// printer would have put it, with PDF export.
struct PrintCentreWindow: View {
    @Bindable var centre = PrintCentre.shared
    @State private var zoom = 1.0
    @State private var showingBytes = false
    @State private var confirmingClear = false

    var body: some View {
        NavigationSplitView {
            List(selection: $centre.selection) {
                ForEach(centre.jobs) { job in
                    JobRow(job: job, pages: job.bytes.isEmpty ? 0 : centre.printout(job).pageCount)
                        .tag(job.id)
                        .contextMenu {
                            Button("Export PDF…") { centre.exportPDF(job) }
                            Button("Save Raw Bytes…") { centre.saveRawBytes(job) }
                            Divider()
                            Button("Delete", role: .destructive) { centre.remove(job.id) }
                        }
                }
            }
            .overlay {
                if centre.jobs.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing Printed", systemImage: "printer")
                    } description: {
                        Text("On a BBC, *FX5,1 then VDU 2 sends what's printed to its printer (VDU 3 stops). On a network, *FX5,4 sends it to the printer server.")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let job = centre.job(centre.selection) {
                JobDetail(job: job, zoom: $zoom, showingBytes: $showingBytes)
            } else {
                ContentUnavailableView("No Job Selected", systemImage: "doc.richtext")
            }
        }
        .navigationTitle("Print Centre")
        .toolbar {
            ToolbarItemGroup {
                Picker("Style", selection: $centre.settings.style) {
                    ForEach(PrintSettings.Style.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Clean type, or dots as a dot-matrix printer makes them")
                Picker("Paper", selection: $centre.settings.paper) {
                    ForEach(PrintSettings.Paper.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .help("The paper it's printed on")
                Toggle("Auto Line Feed", isOn: $centre.settings.autoLineFeed)
                    .help("A carriage return also feeds a line, as a printer set up for the BBC does")
            }
            ToolbarItemGroup {
                if let job = centre.job(centre.selection) {
                    Button { centre.exportPDF(job) } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }
                        .help("Save the printout as a PDF")
                    Button { centre.printOnMac(job) } label: { Label("Print", systemImage: "printer") }
                        .help("Print it on the Mac's printer")
                    Button { showingBytes.toggle() } label: { Label("Raw Bytes", systemImage: "number") }
                        .help("The bytes exactly as the BBC sent them")
                }
                Button { confirmingClear = true } label: { Label("Clear", systemImage: "trash") }
                    .disabled(centre.jobs.isEmpty)
                    .help("Delete every job")
            }
        }
        .confirmationDialog("Delete every print job?", isPresented: $confirmingClear) {
            Button("Delete All", role: .destructive) { centre.removeAll() }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

struct JobRow: View {
    let job: PrintJob
    let pages: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.printer)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                status
            }
            Text(job.started.formatted(date: .abbreviated, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(pages) page\(pages == 1 ? "" : "s") · \(job.bytes.count) bytes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var status: some View {
        switch job.status {
        case .printing:
            Label("Printing", systemImage: "printer.dotmatrix").labelStyle(.iconOnly).foregroundStyle(.green)
                .help("Still printing")
        case .finished:
            EmptyView()
        case .interrupted:
            Label("Interrupted", systemImage: "exclamationmark.triangle.fill").labelStyle(.iconOnly).foregroundStyle(.orange)
                .help("The machine stopped part way through: this is what arrived")
        case .truncated:
            Label("Too long", systemImage: "scissors").labelStyle(.iconOnly).foregroundStyle(.orange)
                .help("Over \(PrintJob.limit / 1024 / 1024)MB: the rest wasn't kept")
        }
    }
}

struct JobDetail: View {
    let job: PrintJob
    @Binding var zoom: Double
    @Binding var showingBytes: Bool
    private var centre: PrintCentre { .shared }

    var body: some View {
        let printout = centre.printout(job)
        VStack(spacing: 0) {
            HStack {
                Text(job.source.map { "From \($0) · " } ?? "")
                    + Text("\(printout.pageCount) page\(printout.pageCount == 1 ? "" : "s")")
                if !printout.unsupported.isEmpty {
                    Label("\(printout.unsupported.values.reduce(0, +)) codes not drawn", systemImage: "info.circle")
                        .help("Printer codes MacBeeb doesn't draw (they're kept in the job): "
                              + printout.unsupported.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
                }
                Spacer()
                Slider(value: $zoom, in: 0.5...2) { Text("Zoom") }
                    .frame(width: 140)
                    .help("Zoom")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if showingBytes {
                RawBytesView(bytes: job.bytes)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            ForEach(0..<printout.pageCount, id: \.self) { index in
                                PageView(printout: printout, index: index, font: centre.font)
                                    .frame(width: printout.settings.paper.size.width * zoom,
                                           height: printout.settings.paper.size.height * zoom)
                                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                                    .id(index)
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    }
                    // While it prints, the page being printed.
                    .onChange(of: printout.pageCount) { _, count in
                        if job.status == .printing, count > 0 {
                            withAnimation { reader.scrollTo(count - 1, anchor: .top) }
                        }
                    }
                }
                // (Each job from its first page.)
                .id(job.id)
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
    }
}

/// One page, drawn by the same code as the PDF.
struct PageView: View {
    let printout: Printout
    let index: Int
    let font: [UInt8]

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                let paper = printout.settings.paper.size
                cg.scaleBy(x: size.width / paper.width, y: size.height / paper.height)
                // SwiftUI's canvas is top-down; the page is drawn bottom-up.
                cg.translateBy(x: 0, y: paper.height)
                cg.scaleBy(x: 1, y: -1)
                printout.draw(page: index, in: cg, font: font)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(index + 1)")
        .accessibilityValue(printout.text(page: index))
    }
}

struct RawBytesView: View {
    let bytes: [UInt8]

    var body: some View {
        ScrollView {
            Text(Self.dump(bytes))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    static func dump(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: min(bytes.count, 65536), by: 16).map { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(row.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%06X  ", offset) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + " " + ascii
        }.joined(separator: "\n")
    }
}

/// A PDF document for printing.
enum PDFDocumentView {
    static func document(_ data: Data) -> PDFDocument? {
        PDFDocument(data: data)
    }
}

/// Window > Print Centre.
struct PrintCentreMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Print Centre") { openWindow(id: PrintCentre.windowID) }
            .keyboardShortcut("p", modifiers: [.command, .option])
    }
}

struct OpenPrintCentreButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Print Centre") { openWindow(id: PrintCentre.windowID) }
    }
}
