import BeebCore
import BeebHost
import SwiftUI

/// The window's toolbar: the common actions, and the machine's lights.
/// Customisable, and hidden with View > Hide Toolbar.
struct MachineToolbar: CustomizableToolbarContent {
    let machine: MachineController

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "model", placement: .navigation) {
            Menu {
                Picker("Model", selection: Binding(get: { machine.model }, set: { machine.setModel($0) })) {
                    ForEach(BBCMicro.Model.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Second Processor", selection: Binding(get: { machine.fittedCoprocessor },
                                                              set: { machine.setCoprocessor($0) })) {
                    Text("No Second Processor").tag(BBCMicro.Coprocessor?.none)
                    ForEach(BBCMicro.Coprocessor.allCases, id: \.self) { coprocessor in
                        Text(coprocessor.displayName).tag(BBCMicro.Coprocessor?.some(coprocessor))
                            .disabled(!coprocessor.fits(machine.model))
                    }
                }
                .pickerStyle(.inline)
                .disabled(!machine.model.hasTube)
                Divider()
                Button("Hardware…") { machine.hardwareRequested = true }
            } label: {
                Label("Model", systemImage: "desktopcomputer")
            }
            .help("Choose the machine (power cycles)")
        }

        ToolbarItem(id: "classics") {
            Button {
                machine.bookshelfRequested = true
            } label: {
                Label("Games", systemImage: "books.vertical")
            }
            .help("The game library: BBC Micro Classics from BBCMicro.co.uk, and your own games")
        }

        ToolbarItem(id: "disc") {
            Menu {
                Button("Open and Boot Disc…") { machine.openDisc() }
                Button("Insert in Drive 0…") { machine.openDisc(drive: 0, boot: false) }
                Button("Insert in Drive 1…") { machine.openDisc(drive: 1, boot: false) }
                Button("New Disc…") { machine.newDisc() }
                Button("Show Disc Contents") { machine.discContentsRequested = true }
                Divider()
                Button("Eject Drive 0") { machine.ejectDisc(drive: 0) }
                    .disabled(machine.discNames[0] == nil)
                Button("Eject Drive 1") { machine.ejectDisc(drive: 1) }
                    .disabled(machine.discNames[1] == nil)
            } label: {
                Label("Disc", systemImage: "opticaldiscdrive")
            } primaryAction: {
                machine.openDisc()
            }
            .disabled(!machine.model.hasDiscInterface)
            .help("Open and boot a disc; hold for more")
        }

        ToolbarItem(id: "tape") {
            Menu {
                Button("Load Tape…") { machine.openTape() }
                Button("Rewind Tape") { machine.rewindTape() }
                    .disabled(machine.tapeName == nil)
                Button("Eject Tape") { machine.ejectTape() }
                    .disabled(machine.tapeName == nil)
            } label: {
                Label("Tape", systemImage: "recordingtape")
            } primaryAction: {
                machine.openTape()
            }
            .disabled(!machine.model.hasCassette)
            .help("Load a tape; hold for more")
        }

        ToolbarItem(id: "break") {
            Button { machine.pressBreak() } label: {
                Label("Break", systemImage: "arrow.counterclockwise")
            }
            .help("Break")
        }

        ToolbarItem(id: "boot", showsByDefault: false) {
            Button { machine.shiftBreak() } label: {
                Label("Boot Disc", systemImage: "arrow.counterclockwise.circle")
            }
            .help("Shift-Break: boot the disc in drive 0")
        }

        ToolbarItem(id: "power") {
            Button { machine.powerCycle() } label: {
                Label("Power Cycle", systemImage: "power")
            }
            .help("Switch off and on again")
        }

        ToolbarItem(id: "rewind") {
            Menu {
                Button("Back 1 Second") { machine.rewind(seconds: 1) }
                Button("Back 5 Seconds") { machine.rewind(seconds: 5) }
                Button("Back 30 Seconds") { machine.rewind(seconds: 30) }
                Divider()
                Button("Timeline…") { machine.showingTimeline = true }
            } label: {
                Label("Rewind", systemImage: "backward.fill")
            } primaryAction: {
                machine.rewind(seconds: 5)
            }
            .help("Go back 5 seconds; hold for more")
        }

        ToolbarItem(id: "pause") {
            Button { machine.togglePause() } label: {
                Label(machine.isStill ? "Resume" : "Pause", systemImage: machine.isStill ? "play.fill" : "pause.fill")
            }
            .help(machine.heldForAgent && !machine.paused ? "Resume (an AI agent is holding the machine between its tool calls)"
                  : machine.paused ? "Resume" : "Pause")
        }

        ToolbarItem(id: "speed") {
            Toggle(isOn: Binding(get: { !machine.speedLimited }, set: { _ in machine.toggleSpeedLimit() })) {
                Label("Full Speed", systemImage: "hare")
            }
            .help("Run as fast as possible")
        }

        ToolbarItem(id: "screenshot") {
            Button { machine.saveScreenshot() } label: {
                Label("Screenshot", systemImage: "camera")
            }
            .help("Save a screenshot")
        }

        ToolbarItem(id: "record") {
            Button { machine.toggleRecording() } label: {
                Label(machine.recordingURL == nil ? "Record" : "Stop Recording",
                      systemImage: machine.recordingURL == nil ? "record.circle" : "stop.circle.fill")
                    .foregroundStyle(machine.recordingURL == nil ? Color.primary : Color.red)
            }
            .help(machine.recordingURL == nil ? "Record a video" : "Stop recording")
        }

        ToolbarItem(id: "state") {
            Menu {
                Button("Save State…") { machine.saveState() }
                Button("Load State…") { machine.loadState() }
            } label: {
                Label("Save State", systemImage: "square.and.arrow.down.on.square")
            } primaryAction: {
                machine.saveState()
            }
            .help("Save the machine's state; hold to load one")
        }

        ToolbarItem(id: "display", showsByDefault: false) {
            Menu {
                Picker("Display", selection: Binding(get: { machine.displayStyle }, set: { machine.displayStyle = $0 })) {
                    ForEach(DisplayStyle.allCases) { style in
                        Text(style.name).tag(style)
                    }
                }
                .pickerStyle(.inline)
                Picker("Monitor", selection: Binding(get: { machine.monitor }, set: { machine.monitor = $0 })) {
                    ForEach(Monitor.allCases) { monitor in
                        Text(monitor.name).tag(monitor)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Display", systemImage: "tv")
            }
            .help("Display style and monitor")
        }

        ToolbarItem(id: "keyboard", showsByDefault: false) {
            Menu {
                Picker("Keyboard", selection: Binding(get: { KeyboardSettings.shared.mode },
                                                      set: { KeyboardSettings.shared.mode = $0 })) {
                    ForEach(KeyboardMode.allCases) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                SettingsLink { Text("Keyboard Settings…") }
            } label: {
                Label("Keyboard", systemImage: "keyboard")
            }
            .help("Keyboard layout")
        }

        ToolbarItem(id: "lights", placement: .primaryAction) {
            HStack(spacing: 0) {
                if machine.servesAgents {
                    AgentLight()
                }
                MachineLights(lights: machine.lights)
            }
        }
    }
}

/// Lit while an agent's attached to this machine (with macbeeb-mcp
/// --attach), and brighter while it's running a tool. Opens MCP > Activity
/// Log.
struct AgentLight: View {
    private let log = AgentLog.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if log.connections > 0 {
            let busy = log.callsRunning > 0
            Button { openWindow(id: AgentLogView.windowID) } label: {
                VStack(spacing: 2) {
                    if busy {
                        // Pulses while a tool runs.
                        dot(busy: true)
                            .phaseAnimator([false, true]) { dot, dim in dot.opacity(dim ? 0.45 : 1) }
                    } else {
                        dot(busy: false)
                    }
                    Text("MCP")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(log.connections == 1 ? "An AI agent is attached (click for the activity log)"
                                       : "\(log.connections) AI agents are attached (click for the activity log)")
            .accessibilityLabel(busy ? "AI agent attached, working" : "AI agent attached")
        }
    }

    private func dot(busy: Bool) -> some View {
        Circle()
            .fill(Color.green.opacity(busy ? 1 : 0.6))
            .shadow(color: busy ? Color.green.opacity(0.9) : .clear, radius: 4)
            .frame(width: 7, height: 7)
    }
}

/// The BBC's keyboard LEDs, the cassette motor and the drive lights.
struct MachineLights: View {
    let lights: BBCMicro.Lights

    var body: some View {
        HStack(spacing: 10) {
            light("CAPS", lights.capsLock, .red)
            light("SHIFT", lights.shiftLock, .red)
            light("MOTOR", lights.cassetteMotor, .red)
            light("0", lights.drives[0], .orange)
            light("1", lights.drives[1], .orange)
        }
        .padding(.horizontal, 6)
        .help("Caps Lock, Shift Lock, cassette motor, drives 0 and 1")
    }

    private func light(_ label: String, _ on: Bool, _ colour: Color) -> some View {
        VStack(spacing: 2) {
            Circle()
                .fill(on ? colour : Color.secondary.opacity(0.25))
                .shadow(color: on ? colour.opacity(0.8) : .clear, radius: 3)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("\(label) light \(on ? "on" : "off")")
    }
}
