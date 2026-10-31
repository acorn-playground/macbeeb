import AppKit
import BeebCore
import BeebNetwork
import SwiftUI
import UniformTypeIdentifiers

/// Machine > ROM Library: the user's sideways ROMs, kept as copies so
/// machines and networks can use them whatever happens to the files.
/// Each has a name and a layout (how a ROM bigger than 16K is switched).
struct ROMLibraryWindow: View {
    static let windowID = "rom-library"
    @State private var selection: Set<String> = []
    @State private var error: String?
    @State private var removing: [UserROM] = []
    @State private var targeted = false

    private var library: ROMLibrary { ROMLibrary.shared }

    var body: some View {
        Group {
            if library.roms.isEmpty {
                ContentUnavailableView {
                    Label("No ROMs", systemImage: "memorychip")
                } description: {
                    Text("Add sideways ROM images (.rom, .bin) to plug them into your machines' sockets. Drop files here, or click Add.")
                } actions: {
                    Button("Add ROMs…", action: add)
                }
            } else {
                table
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 320, idealHeight: 460)
        .navigationTitle("ROM Library")
        .toolbar {
            ToolbarItemGroup {
                Button("Add ROMs…", systemImage: "plus", action: add)
                    .help("Add ROM image files to the library")
                Button("Remove", systemImage: "minus") {
                    removing = library.roms.filter { selection.contains($0.id) }
                }
                .disabled(selection.isEmpty)
                .help("Remove the selected ROMs from the library")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { targeted = $0 }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .alert("ROM Library", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog(removing.count == 1 ? "Remove \(removing[0].name)?" : "Remove \(removing.count) ROMs?",
                            isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } })) {
            Button("Remove", role: .destructive) {
                for rom in removing { try? library.remove(rom.id) }
                selection = []
                removing = []
            }
        } message: {
            Text("Machines with it in a socket will say it's missing. Networks keep their own copies, so they still have it.")
        }
    }

    private var table: some View {
        Table(library.roms, selection: $selection) {
            TableColumn("Name") { rom in
                TextField("Name", text: Binding(get: { rom.name }, set: { name in
                    var renamed = rom
                    renamed.name = name
                    try? library.update(renamed)
                }))
                .textFieldStyle(.plain)
            }
            .width(min: 160, ideal: 230)
            TableColumn("ROM") { rom in
                Text(rom.title.map { [$0, rom.version].compactMap { $0 }.joined(separator: " ") } ?? "No ROM header")
                    .foregroundStyle(rom.title == nil ? .secondary : .primary)
                    .help(rom.copyright ?? "")
            }
            .width(min: 120, ideal: 160)
            TableColumn("Type") { rom in
                Text(rom.title == nil ? "—" : rom.isLanguage ? "Language" : "Service")
                    .foregroundStyle(.secondary)
            }
            .width(70)
            TableColumn("Layout") { rom in
                layoutPicker(rom)
            }
            .width(min: 150, ideal: 180)
            TableColumn("Size") { rom in
                Text(rom.size >= 1024 ? "\(rom.size / 1024)K" : "\(rom.size) bytes")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(60)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(ids.map {
                    library.folder.appendingPathComponent(ROMSource.fileName(for: $0))
                })
            }
            Button("Remove…", role: .destructive) {
                removing = library.roms.filter { ids.contains($0.id) }
            }
        }
    }

    @ViewBuilder
    private func layoutPicker(_ rom: UserROM) -> some View {
        let layouts = library.data(for: rom.id).map(ROMLayout.candidates(for:)) ?? [rom.layout]
        if layouts.count > 1 {
            Picker("Layout", selection: Binding(get: { rom.layout }, set: { layout in
                var changed = rom
                changed.layout = layout
                try? library.update(changed)
            })) {
                ForEach(layouts, id: \.self) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            .labelsHidden()
            .help("How the ROM goes into a machine: two 16K ROMs in one chip, or one ROM switched by its own hardware")
        } else {
            Text(rom.layout.displayName)
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.prompt = "Add"
        panel.message = "Sideways ROM images: 16K or less, or 32K, 64K or 128K. They're copied into the library."
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.data]
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        var problems: [String] = []
        var added: Set<String> = []
        for url in urls {
            do {
                added.insert(try library.add(fileAt: url).id)
            } catch {
                problems.append("\(error)")
            }
        }
        if !added.isEmpty { selection = added }
        if !problems.isEmpty { error = problems.joined(separator: "\n") }
    }
}
