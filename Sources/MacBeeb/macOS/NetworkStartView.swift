import AppKit
import BeebNetwork
import SwiftUI
import UniformTypeIdentifiers

/// File > New Network: choose a template (or reopen a recent network).
struct NetworkStartView: View {
    static let windowID = "network-start"
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Network")
                    .font(.largeTitle.weight(.semibold))
                Text("BBC Micros that share a network, each running for real. Start from one of these, then add, arrange and use the machines.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                ForEach(NetworkTemplate.allCases) { template in
                    Button { create(template) } label: {
                        TemplateCard(template: template)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !RecentNetworks.shared.existing.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent")
                        .font(.headline)
                    ForEach(RecentNetworks.shared.existing.prefix(5), id: \.self) { url in
                        Button {
                            NetworkStudioCommands.open(url, openWindow: openWindow)
                            dismissWindow(id: Self.windowID)
                        } label: {
                            Label(url.deletingPathExtension().lastPathComponent, systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .buttonStyle(.link)
                        .help(url.path)
                    }
                }
            }
            HStack {
                Button("Open Network…") {
                    if NetworkStudioCommands.chooseAndOpen(openWindow: openWindow) {
                        dismissWindow(id: Self.windowID)
                    }
                }
                Spacer()
                Text("New networks are saved as you work; closing one asks whether to keep it, and where.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 720)
        .alert("Can’t make the network", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func create(_ template: NetworkTemplate) {
        do {
            let url = try NetworkStudioCommands.createDraft(template)
            NetworkStudioCommands.open(url, openWindow: openWindow)
            dismissWindow(id: Self.windowID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TemplateCard: View {
    let template: NetworkTemplate
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: template.symbolName)
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
                .frame(height: 34)
            Text(template.title)
                .font(.headline)
            Text(template.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(hovering ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(hovering ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Opening networks, from the menus and the start page.
@MainActor
enum NetworkStudioCommands {
    /// Posted (with the package's URL) to have a network's window opened,
    /// by whichever window can.
    static let openRequest = Notification.Name("MacBeebOpenNetworkWindow")
    /// Posted (with the package's URL) to show a network's Share Over
    /// Internet sheet.
    static let shareRequest = Notification.Name("MacBeebShareNetwork")

    /// A new network from a template, as a draft: closing it asks whether
    /// to keep it.
    static func createDraft(_ template: NetworkTemplate) throws -> URL {
        let url = RecentNetworks.newURL(named: template.title)
        var project = try NetworkPackage.create(template, at: url)
        project.draft = true
        try NetworkPackage.save(project, to: url)
        return url
    }

    static func open(_ url: URL, openWindow: OpenWindowAction) {
        openWindow(id: NetworkStudioWindow.windowID, value: url.standardizedFileURL)
    }

    /// File > Open Network…; returns whether one was opened.
    @discardableResult
    static func chooseAndOpen(openWindow: OpenWindowAction) -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.macBeebNetwork]
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = RecentNetworks.folder
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        open(url, openWindow: openWindow)
        return true
    }

    /// Window > Network Studio: the network that's open, else the last one,
    /// else a new one.
    static func showStudio(openWindow: OpenWindowAction) {
        if let url = NetworkSession.open.keys.first ?? RecentNetworks.shared.existing.first {
            open(url, openWindow: openWindow)
        } else {
            openWindow(id: NetworkStartView.windowID)
        }
    }
}

/// File menu items for networks.
struct NetworkMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(NetworkSession.self) private var session

    var body: some View {
        Button("New Network…") { openWindow(id: NetworkStartView.windowID) }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        Button("Open Network…") { NetworkStudioCommands.chooseAndOpen(openWindow: openWindow) }
        JoinRoomMenuItem()
        Button(session?.isInRoom == true ? "Internet Network…" : "Share Network Over Internet…") {
            if let session { NotificationCenter.default.post(name: NetworkStudioCommands.shareRequest, object: session.url) }
        }
        .disabled(session == nil)
        Menu("Open Recent Network") {
            ForEach(RecentNetworks.shared.existing, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) { NetworkStudioCommands.open(url, openWindow: openWindow) }
                    .help(url.path)
            }
        }
        .disabled(RecentNetworks.shared.existing.isEmpty)
        Button("Save Network As…") { saveAs() }
            .disabled(session == nil)
    }

    private func saveAs() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.macBeebNetwork]
        panel.nameFieldStringValue = session.url.lastPathComponent
        panel.directoryURL = session.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.saveAs(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Window > Network Studio.
struct NetworkStudioMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Network Studio") { NetworkStudioCommands.showStudio(openWindow: openWindow) }
            .keyboardShortcut("0", modifiers: [.command, .option])
    }
}

extension UTType {
    static let macBeebNetwork = UTType(exportedAs: "com.accidentalfish.macbeeb.network", conformingTo: .package)
}
