import AppKit
import BeebCore
import BeebHost
import BeebNetwork
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            KeyboardSettingsView()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
            GamepadSettingsView()
                .tabItem { Label("Gamepad", systemImage: "gamecontroller") }
            DebuggingSettingsView()
                .tabItem { Label("Debugging", systemImage: "ladybug") }
            ClassicsSettingsView()
                .tabItem { Label("Games", systemImage: "books.vertical") }
            NetworkingSettingsView()
                .tabItem { Label("Networking", systemImage: "globe") }
        }
        .frame(width: 520, height: 460)
    }
}

/// Which Internet Econet service rooms are made and codes looked up on.
struct NetworkingSettingsView: View {
    @State private var custom = !InternetEconetService.isOfficial
    @State private var address = InternetEconetService.isOfficial ? "" : InternetEconetService.current.absoluteString
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Picker("Internet Econet Service", selection: $custom) {
                    Text("Official service (\(InternetEconetService.officialURL.host ?? ""))").tag(false)
                    Text("Custom service").tag(true)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: custom) {
                    result = nil
                    if !custom { InternetEconetService.current = InternetEconetService.officialURL }
                }
                if custom {
                    TextField("Address", text: $address, prompt: Text("https://econet.example.org"))
                        .onSubmit { apply() }
                    if let problem {
                        Text(problem)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    if let url = try? InternetEconetService.validate(address).get(), InternetEconetService.isLocalDevelopment(url) {
                        Label("Developer mode: an unencrypted service on this Mac.", systemImage: "hammer")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                HStack {
                    Button("Test Connection", action: test)
                        .disabled(testing || (custom && address.isEmpty))
                    if testing { ProgressView().controlSize(.small) }
                    if let result {
                        Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.ok ? .green : .red)
                    }
                    Spacer()
                    Button("Reset to Default") {
                        custom = false
                        address = ""
                        problem = nil
                        InternetEconetService.current = InternetEconetService.officialURL
                    }
                    .disabled(!custom)
                }
                Text("Sharing a network over the Internet makes its room here, and join codes are looked up here. Anyone can run a compatible service of their own (cloudflare-econet, on Cloudflare); invitation links name theirs. Each service keeps its own rooms and credentials.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("cloudflare-econet on GitHub", destination: URL(string: "https://github.com/JamesRandall/cloudflare-econet")!)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    /// Takes the typed address, if it's a good one.
    @discardableResult
    private func apply() -> URL? {
        guard custom else { return InternetEconetService.officialURL }
        switch InternetEconetService.validate(address) {
        case .success(let url):
            problem = nil
            address = url.absoluteString
            InternetEconetService.current = url
            return url
        case .failure(let error):
            problem = error.description
            return nil
        }
    }

    private func test() {
        guard let url = apply() else { return }
        testing = true
        result = nil
        Task {
            defer { testing = false }
            do {
                let info = try await RoomAPI(service: url).serviceInfo()
                if let incompatibility = info.incompatibility {
                    result = (false, incompatibility)
                } else {
                    result = (true, "\(info.name): compatible, protocol \(ServiceInfo.protocolVersion)")
                }
            } catch {
                result = (false, "No Internet Econet service answered at \(url.host ?? url.absoluteString)")
            }
        }
    }
}

/// What MacBeeb opens with.
struct GeneralSettingsView: View {
    @AppStorage(LaunchScreen.defaultsKey) private var launchScreen = LaunchScreen.preference

    var body: some View {
        Form {
            Section {
                Picker("When MacBeeb opens, show", selection: $launchScreen) {
                    ForEach(LaunchScreen.allCases) { screen in
                        Text(screen.title).tag(screen)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("The welcome screen leads to everything: a BBC Micro, the Game Library and the Network Studio. With it, closing your last window brings it back, and closing it quits MacBeeb. Opening with the Game Library suits playing games: choose one and its BBC Micro opens, set up to play it. The Network Studio opens the network you used last. Takes effect the next time MacBeeb opens; Window ▸ Welcome to MacBeeb shows the welcome screen any time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

struct KeyboardSettingsView: View {
    @State private var settings = KeyboardSettings.shared
    @State private var recorder: KeyRecorder?

    var body: some View {
        Form {
            Section {
                Picker("Keys", selection: $settings.mode) {
                    ForEach(KeyboardMode.allCases) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.mode == .physical
                     ? "Each Mac key is the BBC key in the same place: Shift-8 types “(” as on a BBC. Best for games."
                     : "Keys type what the Mac's layout says: Shift-8 types “*”. Best for typing. Control, the arrows and function keys still go by position, and Option types characters rather than being Shift Lock.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                DiscPicker()
                if settings.mappings(for: disc).isEmpty {
                    Text(disc == nil
                         ? "No custom keys. Add one to put any BBC key on any Mac key (it takes priority in both modes)."
                         : "No keys for this disc. Keys added here apply while it's in drive 0, on top of the keys for all discs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.mappings(for: disc)) { mapping in
                    HStack {
                        Text(mapping.macKeyName)
                            .frame(minWidth: 120, alignment: .leading)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Picker("BBC key", selection: Binding(
                            get: { mapping.key },
                            set: { settings.setMapping(keyCode: mapping.keyCode, macKeyName: mapping.macKeyName, to: $0,
                                                       disc: disc) }
                        )) {
                            ForEach(BeebKey.catalogue, id: \.key) { entry in
                                Text(entry.name).tag(entry.key)
                            }
                        }
                        .labelsHidden()
                        Button {
                            settings.removeMapping(keyCode: mapping.keyCode, disc: disc)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            } header: {
                Text("Custom keys")
            } footer: {
                HStack {
                    if recorder != nil {
                        Text("Press the Mac key to map…")
                            .foregroundStyle(.secondary)
                        Button("Cancel") { stopRecording() }
                    } else {
                        Button("Add Mapping…") { startRecording() }
                    }
                    Spacer()
                    Button("Remove All") { settings.removeAllMappings(disc: disc) }
                        .disabled(settings.mappings(for: disc).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    /// The disc whose keys are showing (nil: all discs').
    private var disc: String? { settings.editingDisc }

    private func startRecording() {
        let disc = disc
        recorder = KeyRecorder { event in
            let name = KeyboardSettings.name(of: event)
            // Start from what the key does now, then let the user pick.
            let current = settings.translator(disc: disc).translate(keyCode: event.keyCode, characters: event.characters,
                                                                    modifiers: .init(event.modifierFlags))?.key ?? .space
            settings.setMapping(keyCode: event.keyCode, macKeyName: name, to: current, disc: disc)
            stopRecording()
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
    }
}

/// Which settings the keyboard and gamepad tabs show: all discs', or a disc
/// image's own (`KeyboardSettings.editingDisc`, shared by both).
struct DiscPicker: View {
    @State private var settings = KeyboardSettings.shared

    var body: some View {
        Picker("For", selection: $settings.editingDisc) {
            Text("All discs").tag(String?.none)
            if !discs.isEmpty {
                Divider()
            }
            ForEach(discs, id: \.self) { path in
                Text(Self.discName(path)).tag(String?.some(path))
            }
        }
    }

    /// Discs to choose from: those in the machines' drive 0, those with
    /// settings of their own, and the one showing.
    private var discs: [String] {
        let all = MachineController.all.values.compactMap(\.bootDiscPath) + settings.discMappings.keys
            + GamepadSettings.shared.discConfigs.keys + [settings.editingDisc].compactMap { $0 }
        return Set(all).sorted { Self.discName($0).localizedStandardCompare(Self.discName($1)) == .orderedAscending }
    }

    /// "Elite.ssd (Games)": the image's name and its folder's.
    static func discName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return "\(url.lastPathComponent) (\(url.deletingLastPathComponent().lastPathComponent))"
    }
}

struct GamepadSettingsView: View {
    @State private var settings = GamepadSettings.shared
    @State private var keyboard = KeyboardSettings.shared

    /// The disc whose settings are showing (nil: all discs').
    private var disc: String? { keyboard.editingDisc }

    var body: some View {
        let config = settings.config(for: disc)
        let mode = settings.mapping(disc: disc).mode
        Form {
            Section {
                DiscPicker()
                Picker("Controller is", selection: Binding(get: { config.mode }, set: { settings.setMode($0, disc: disc) })) {
                    if disc != nil {
                        Text("As for all discs (\(settings.config.mode?.name ?? "Joystick"))").tag(GamepadMode?.none)
                    }
                    ForEach(GamepadMode.allCases) { mode in
                        Text(mode.name).tag(GamepadMode?.some(mode))
                    }
                }
                Text(mode == .joystick
                     ? "The first controller is joystick 0 and the second joystick 1: the d-pad or left stick moves it, and A or the right trigger fires. Other buttons press the keys below."
                     : "Each button, and each direction of the d-pad and left stick, presses the key below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(GamepadButton.allCases) { button in
                    HStack {
                        Text(button.name)
                            .fontWeight(settings.held.contains(button) ? .bold : .regular)
                            .frame(minWidth: 140, alignment: .leading)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        if mode == .joystick && button.isJoystick {
                            Text("Joystick")
                                .foregroundStyle(.secondary)
                            Spacer()
                        } else {
                            Picker("BBC key", selection: Binding(
                                get: { config.key(for: button) },
                                set: { settings.setKey($0, for: button, disc: disc) }
                            )) {
                                Text(disc == nil ? "None" : "As for all discs (\(settings.config.key(for: button)?.name ?? "none"))")
                                    .tag(BeebKey?.none)
                                ForEach(BeebKey.catalogue, id: \.key) { entry in
                                    Text(entry.name).tag(BeebKey?.some(entry.key))
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }
            } header: {
                Text("Buttons")
            } footer: {
                HStack {
                    Text("Press a button to see which it is.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(disc == nil ? "Reset" : "Remove This Disc's Settings") { settings.reset(disc: disc) }
                        .disabled(disc == nil ? config == GamepadSettings.Config(mode: .joystick) : config.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Captures the next key press (including modifier keys) in the app.
@MainActor
final class KeyRecorder {
    private var monitor: Any?

    init(onKey: @escaping (NSEvent) -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Modifier presses only: ignore their releases.
            if event.type == .flagsChanged && !Self.isPress(event) {
                return nil
            }
            onKey(event)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private static func isPress(_ event: NSEvent) -> Bool {
        let flag: NSEvent.ModifierFlags = switch event.keyCode {
        case 0x38, 0x3C: .shift
        case 0x3B, 0x3E: .control
        case 0x3A, 0x3D: .option
        case 0x37, 0x36: .command
        case 0x39: .capsLock
        default: .function
        }
        return event.modifierFlags.contains(flag)
    }
}

struct DebuggingSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MachineController.debugAdapterEnabledKey) private var enabled = true
    @AppStorage(MachineController.debugAdapterPortKey) private var port = Int(6502)

    var body: some View {
        Form {
            Section {
                Toggle("Let editors debug the BBC (Debug Adapter Protocol)", isOn: $enabled)
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .disabled(!enabled)
                Text("VS Code and other editors that speak DAP connect to localhost on this port, to set breakpoints in your source, step, and inspect the machine. Changes take effect next launch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("VS Code") {
                LabeledContent("The MacBeeb extension") {
                    Link("Visual Studio Marketplace", destination: VSCodeExtension.marketplace)
                }
                LabeledContent("How to use it") {
                    Button("Debugging with VS Code Guide") { openWindow(id: GuideWindow.windowID, value: "vscode") }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The BBC Micro Classics bookshelf: whether, and where, to look for
/// downloaded games.
struct ClassicsSettingsView: View {
    @State private var classics = ClassicsLibrary.shared

    var body: some View {
        Form {
            Section {
                Toggle("Add downloaded Classics automatically", isOn: Binding(
                    get: { classics.autoDetect == true },
                    set: { classics.autoDetect = $0 }
                ))
                Text("When you get a game from BBCMicro.co.uk, MacBeeb looks for the disc image in this folder and adds it to the bookshelf once the download finishes. It only reads the folder, only while MacBeeb is open, and never changes your downloads.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Folder") {
                    HStack {
                        Text(classics.downloadFolder.path(percentEncoded: false)
                            .replacingOccurrences(of: URL.homeDirectory.path(percentEncoded: false), with: "~/"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                if classics.downloadFolder != ClassicsLibrary.defaultDownloadFolder {
                    Button("Use Downloads") { classics.downloadFolder = ClassicsLibrary.defaultDownloadFolder }
                }
                switch classics.watchState {
                case .off:
                    EmptyView()
                case .watching:
                    Label("Looking for downloaded games", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                case .noAccess(let reason):
                    Label("MacBeeb can’t read this folder: \(reason) Allow it in System Settings ▸ Privacy & Security ▸ Files & Folders, or choose another folder.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("You can always add games with Import Disc… on the bookshelf, or by dragging disc images onto it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// For browsers that save somewhere other than Downloads.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = classics.downloadFolder
        panel.message = "Choose the folder your browser saves downloads to."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        classics.downloadFolder = url
    }
}
