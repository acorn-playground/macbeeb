import AppKit
import BeebCore
import BeebNetwork
import SwiftUI
import UniformTypeIdentifiers

/// The network's traffic: every frame on the line, as the four-way
/// handshake reads them, with what's in them.
struct NetworkTrafficView: View {
    @Bindable var session: NetworkSession
    @State private var frames: [EconetFrame] = []
    @State private var selection: EconetFrame.ID?
    @State private var station: Int?
    @State private var problemsOnly = false
    @State private var search = ""
    @State private var recording = true
    /// The Distributed Mandelbrot demo's messages, by transaction.
    @State private var reader = MandelbrotTraffic()
    @State private var readings: [Int: MandelbrotReading] = [:]

    static let refresh = 0.25

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                table
                    .frame(minWidth: 420, maxHeight: .infinity)
                detail
                    .frame(minWidth: 280, idealWidth: 340, maxHeight: .infinity)
            }
            // (Both sides fill the height: with no frame chosen, the detail's
            // only a placeholder, which would otherwise shrink the table.)
            .frame(maxHeight: .infinity)
        }
        .task {
            recording = session.runtime.network.isTracing
            while !Task.isCancelled {
                let newer = session.runtime.network.frames(after: frames.last?.id)
                if !newer.isEmpty {
                    for frame in newer {
                        if let reading = reader.read(frame), let transaction = frame.transaction { readings[transaction] = reading }
                    }
                    frames.append(contentsOf: newer)
                    if frames.count > 4096 {
                        frames.removeFirst(frames.count - 4096)
                        let first = frames.first?.transaction ?? 0
                        readings = readings.filter { $0.key >= first }
                    }
                }
                try? await Task.sleep(for: .seconds(Self.refresh))
            }
        }
    }

    /// The frames listed: newest first (only the latest are kept).
    private var shown: [EconetFrame] {
        frames.reversed().filter { frame in
            if let station, frame.transmitter != UInt8(clamping: station) && frame.destinationStation != UInt8(clamping: station) {
                return false
            }
            if problemsOnly && frame.status == .valid { return false }
            if !search.isEmpty {
                let text = search.lowercased()
                let bytes = String(decoding: frame.bytes.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, as: UTF8.self).lowercased()
                let hex = frame.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                if !summary(frame).lowercased().contains(text) && !bytes.contains(text) && !hex.contains(text) { return false }
            }
            return true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Toggle(isOn: Binding(get: { recording }, set: { on in
                recording = on
                session.runtime.network.setTracing(on)
            })) {
                Label(recording ? "Recording" : "Paused", systemImage: recording ? "record.circle" : "pause.circle")
            }
            .toggleStyle(.button)
            .fixedSize()
            .help("Record frames as they cross the line")
            Button {
                session.runtime.network.clearTrace()
                frames = []
                selection = nil
                reader = MandelbrotTraffic()
                readings = [:]
            } label: { Label("Clear", systemImage: "trash") }
                .fixedSize()
            Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                .fixedSize()
                .disabled(frames.isEmpty)
                .help("Save the frames as JSON (MacBeeb's own format, not PCAP)")
            Divider().frame(height: 18)
            Picker("Station", selection: $station) {
                Text("All stations").tag(Int?.none)
                ForEach(session.project.stations, id: \.id) { node in
                    if let number = node.stationNumber {
                        Text("\(node.name) (\(number))").tag(Int?.some(number))
                    }
                }
            }
            .fixedSize()
            Toggle("Problems only", isOn: $problemsOnly)
                .fixedSize()
            TextField("Search bytes or text", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 110, maxWidth: 200)
            Spacer()
            totals
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var totals: some View {
        let traffic = session.status.traffic
        let frames = traffic.values.reduce(0) { $0 + $1.frames }
        let collisions = traffic.values.reduce(0) { $0 + $1.collisions }
        return Text("\(frames) frames sent · \(collisions) byte-times collided")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(-1)
            .help("Counted on the line since the network opened")
    }

    // MARK: Table

    private var table: some View {
        Table(shown, selection: $selection) {
            TableColumn("Time") { frame in
                Text(String(format: "%.3f s", Double(frame.start) / 2_000_000))
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("From") { frame in Text(name(frame.transmitter)) }
                .width(min: 60, ideal: 90)
            TableColumn("To") { frame in Text(frame.destinationStation.map(name) ?? "–") }
                .width(min: 60, ideal: 90)
            TableColumn("Frame") { frame in
                Label(summary(frame), systemImage: symbol(frame))
                    .foregroundStyle(frame.status == .valid ? .primary : Color.orange)
            }
            TableColumn("#") { frame in Text(frame.transaction.map(String.init) ?? "") }
                .width(min: 30, ideal: 40)
        }
        .onChange(of: selection) {
            // Show who's involved on the canvas too.
            guard let frame = frames.first(where: { $0.id == selection }) else { return }
            let stations = [frame.transmitter, frame.destinationStation].compactMap { $0 }
            session.selection = Set(session.project.nodes.filter { node in
                node.stationNumber.map { stations.contains(UInt8(clamping: $0)) } ?? false
            }.map(\.id))
        }
    }

    /// The demo's message in a data frame, if it's one.
    private func reading(_ frame: EconetFrame) -> MandelbrotReading? {
        guard frame.kind == .data, let transaction = frame.transaction else { return nil }
        return readings[transaction]
    }

    /// The frame, and what's in it where that's known.
    private func summary(_ frame: EconetFrame) -> String {
        reading(frame).map { frame.summary + " · " + $0.summary } ?? frame.summary
    }

    /// What a frame's port is for: the demo's name, if its data was the demo's.
    private func portName(_ frame: EconetFrame) -> String? {
        guard let port = frame.port else { return nil }
        if let transaction = frame.transaction, readings[transaction] != nil, let name = MandelbrotProtocol.portName(port) {
            return name
        }
        return EconetFrame.portName(port)
    }

    private func name(_ station: UInt8) -> String {
        if station == 255 { return "Everyone" }
        return session.project.nodes.first { $0.stationNumber == Int(station) }?.name ?? "Station \(station)"
    }

    private func symbol(_ frame: EconetFrame) -> String {
        switch frame.status {
        case .collided: return "exclamationmark.triangle"
        case .aborted: return "xmark.octagon"
        case .valid:
            switch frame.kind {
            case .scout: return "arrow.right.circle"
            case .acknowledgement: return "checkmark.circle"
            case .data: return "doc.circle"
            case .broadcast: return "dot.radiowaves.left.and.right"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let frame = frames.first(where: { $0.id == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(frame.summary).font(.headline)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                        row("From", name(frame.transmitter) + " (\(frame.transmitter))")
                        if let to = frame.destinationStation { row("To", name(to) + " (\(to)), network \(frame.destinationNetwork ?? 0)") }
                        row("Status", explanation(frame.status))
                        row("Length", "\(frame.bytes.count) bytes, \(String(format: "%.2f ms", Double(frame.end - frame.start) / 2000)) on the line")
                        if let transaction = frame.transaction { row("Transaction", "#\(transaction): " + (kindText(frame.kind))) }
                        if let name = portName(frame) { row("Port", name) }
                    }
                    .font(.callout)
                    if let reading = reading(frame) {
                        mandelbrot(reading)
                    }
                    Text(RawBytesView.dump(frame.bytes))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Bytes 0-3 are who it's to and from (station, network); a scout's byte 4 is the control byte and byte 5 the port. The check bytes aren't shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label("No Frame Selected", systemImage: "waveform.path")
            } description: {
                Text(frames.isEmpty ? "Nothing's crossed the line yet. Try *NET then *CAT on a machine." : "Choose a frame to see what's in it.")
            }
        }
    }

    /// The application layer: a Distributed Mandelbrot message.
    private func mandelbrot(_ reading: MandelbrotReading) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Label(MandelbrotProtocol.portName(reading.port) ?? "Mandelbrot", systemImage: "square.grid.3x3.square")
                .font(.subheadline.weight(.semibold))
            switch reading.message {
            case .success(let message):
                Text(message.summary(to: reading.to))
                    .textSelection(.enabled)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(Array(message.fields.enumerated()), id: \.offset) { _, field in
                        row(field.label, field.value)
                    }
                }
                .font(.callout)
            case .failure(let error):
                Label("Not a Distributed Mandelbrot message: \(error.description)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func explanation(_ status: EconetFrame.Status) -> String {
        switch status {
        case .valid: "Complete: closed with its check bytes"
        case .collided: "Spoiled: another station was transmitting at the same time"
        case .aborted: "Abandoned part way: the transmitter stopped or ran dry"
        }
    }

    private func kindText(_ kind: EconetFrame.Kind) -> String {
        switch kind {
        case .scout: "the scout, asking to send"
        case .acknowledgement: "an acknowledgement"
        case .data: "the data"
        case .broadcast: "a broadcast"
        case .unknown: "not recognised"
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(session.project.name) traffic.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let export = TrafficExport(network: session.project.name, cyclesPerSecond: 2_000_000, frames: frames)
            try encoder.encode(export).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// A traffic capture as saved: MacBeeb's own JSON, documented in the
/// Network Studio guide.
struct TrafficExport: Codable {
    var format = "MacBeeb Econet trace 1"
    var network: String
    /// The frames' times are in these.
    var cyclesPerSecond: Int
    var frames: [EconetFrame]
}
