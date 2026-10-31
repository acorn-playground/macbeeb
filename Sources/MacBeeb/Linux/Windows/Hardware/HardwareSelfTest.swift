import BeebCore
import BeebNetwork
import CGtk
import Foundation

/// The Hardware window's self-test (the Mac's is HardwareSelfTest): with
///
///     -MacBeebSelfTest /dir/out.png -MacBeebSelfTestOpen win.hardware -MacBeebSelfTestWait 60
///     -MacBeebHardwareSelfTest stock,pending,watford,aries,b12,master,bplus,nula,library,configurations,configuration
///     -MacBeebHardwareSelfTestROMs /dir/of/roms   (added to the ROM library first)
///
/// it takes the window through each step in turn (a draft, or hardware
/// fitted and the BBC restarted), and saves the window and the whole of its
/// content as out-hw-STEP.png and out-hw-STEP-content.png, with what the
/// machine's banks hold in out-hw.txt. Run it with its own XDG_DATA_HOME
/// and XDG_CONFIG_HOME (or -MacBeebROMLibraryFolder and
/// -MacBeebMachinesFile), so the ROMs and configurations it adds aren't the
/// user's.
@MainActor
enum HardwareSelfTest {
    private static var started = false

    private static var steps: [String]? {
        UserDefaults.standard.string(forKey: "MacBeebHardwareSelfTest")?.split(separator: ",").map(String.init)
    }

    private static var path: String? { UserDefaults.standard.string(forKey: "MacBeebSelfTest") }

    /// A window opened: the first Hardware window starts the test.
    static func windowShown(key: String) {
        guard let steps, let path, !started, key.hasPrefix("hardware-"),
              let controller = HardwareExpansionsWindow.controller(key) else { return }
        started = true
        Task { await run(steps, controller, path) }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func run(_ steps: [String], _ controller: HardwareWindowController, _ path: String) async {
        var report = ""
        if let folder = UserDefaults.standard.string(forKey: "MacBeebHardwareSelfTestROMs"),
           let files = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.path < $1.path }) where ["rom", "bin"].contains(file.pathExtension) {
                _ = try? ROMLibrary.shared.add(fileAt: file)
            }
        }
        report += "ROMs in the library: \(ROMLibrary.shared.roms.map(\.name).joined(separator: ", "))\n"
        func rom(_ prefix: String) -> SocketContent? {
            if prefix == "Missing" {
                // One that isn't in the library.
                return .rom(PluggedROM(id: String(repeating: "0", count: 64), name: "Inter-Base", layout: .single))
            }
            return ROMLibrary.shared.roms.first { $0.name.hasPrefix(prefix) }.map { .rom($0.plugged) }
        }
        let model = controller.model
        let window = controller.window
        window.setDefaultSize(width: 760, height: 1000)
        // (The content's own pictures have the window's background.)
        controller.column.style("hw-capture")
        func fit(_ change: (inout MachineController.HardwareDraft) -> Void) async {
            var draft = model.target.hardwareDraft
            change(&draft)
            model.target.apply(draft)
            await pause(3.5)
        }
        func capture(_ step: String, _ widget: Widget? = nil) async {
            await pause(0.8)
            Capture.write(widget ?? window, to: path.replacingOccurrences(of: ".png", with: "-hw-\(step).png"))
            if widget == nil {
                Capture.write(controller.column, to: path.replacingOccurrences(of: ".png", with: "-hw-\(step)-content.png"))
            }
            let banks = model.snapshot?.slots.map { "\($0.bank):\($0.kind.rawValue)\($0.header.map { " " + $0.name } ?? "")" } ?? []
            report += "\(step): \(model.draft.model.displayName), \(model.draft.expansions.board.displayName), pending \(model.pending); banks \(banks.joined(separator: ", "))\n"
        }
        for step in steps {
            switch step {
            case "stock":
                await capture(step)
            case "pending":
                model.draft.expansions = BBCMicro.Expansions(board: .watford32K, sidewaysRAM: .ram32)
                await capture(step)
                model.draft = model.target.hardwareDraft
            case "watford":
                await fit {
                    $0.model = .modelB
                    $0.expansions = BBCMicro.Expansions(board: .watford32K, sidewaysRAM: .ram16, sidewaysRAMSocket: 12)
                }
                if let hello = rom("hello"), case .rom(let plugged) = hello, let running = model.running,
                   let data = ROMLibrary.shared.data(for: plugged.id) {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-hardware-\(UUID().uuidString).rom")
                    try? Data(data).write(to: file)
                    try? await running.loadSidewaysImage(file, bank: 12)
                    try? FileManager.default.removeItem(at: file)
                    running.setPowerOnImage(URL(fileURLWithPath: "/tmp/Example.rom"), bank: 12)
                }
                await capture(step)
                model.running?.setPowerOnImage(nil, bank: 12)
            case "aries":
                await fit {
                    $0.model = .modelB
                    $0.expansions = BBCMicro.Expansions(board: .ariesB32, sidewaysRAM: .ram32)
                }
                await capture(step)
            case "b12":
                await fit {
                    $0.model = .modelB
                    $0.expansions = BBCMicro.Expansions(board: .ariesB32B12)
                    $0.sockets = SocketSetup(roms: [1: rom("hello")].compactMapValues { $0 })
                }
                await capture(step)
            case "master":
                await fit {
                    $0.model = .master128
                    $0.sockets = SocketSetup(roms: [0: rom("hello"), 1: rom("Missing"), 4: rom("Pair")].compactMapValues { $0 },
                                             cartridges: [0: .roms, 1: .ram32], romLinks: [4])
                }
                await capture(step)
            case "bplus":
                await fit {
                    $0.model = .bPlus
                    $0.sockets = SocketSetup(roms: [2: rom("Pair"), 14: .empty, 9: rom("hello")].compactMapValues { $0 })
                }
                await capture(step)
            case "modela":
                model.draft.model = .modelA
                await capture(step)
                model.draft = model.target.hardwareDraft
            case "nula":
                await fit {
                    $0.model = .modelB
                    $0.expansions = .none
                    $0.sockets = .standard
                    $0.videoNuLA = true
                }
                model.running?.host.send(.type("VDU 19,1,4,0,0,15\n"))
                await pause(1.5)
                await capture(step)
            case "stock-again":
                await fit {
                    $0.model = .modelB
                    $0.expansions = .none
                    $0.sockets = .standard
                    $0.videoNuLA = false
                }
                await capture(step)
            case "save-dialog":
                saveConfiguration(model.target.setup, over: window)
                await capture(step)
            case "library":
                ROMLibraryWindow.show()
                await pause(1)
                if let library = Windows.existing("rom-library") {
                    await capture(step, library)
                }
            case "configurations":
                var setup = model.target.setup
                _ = try? MachineConfigurations.shared.save(setup, as: "Self-Test Machine")
                setup.model = .master128
                setup.sockets = SocketSetup(roms: [0: rom("Missing")].compactMapValues { $0 }, cartridges: [0: .roms, 1: .ram32])
                _ = try? MachineConfigurations.shared.save(setup, as: "Self-Test Master")
                MachineConfigurationsWindow.show()
                await pause(1)
                if let configurations = Windows.existing("configurations") {
                    await capture(step, configurations)
                }
            case "configuration":
                if let saved = MachineConfigurations.shared.machines.first(where: { $0.name == "Self-Test Master" }) {
                    HardwareExpansionsWindow.show(ref: .configuration(saved.id))
                    await pause(1)
                    if let other = HardwareExpansionsWindow.controller("hardware-configuration-\(saved.id)") {
                        other.window.setDefaultSize(width: 760, height: 1000)
                        other.column.style("hw-capture")
                        await pause(1)
                        Capture.write(other.window, to: path.replacingOccurrences(of: ".png", with: "-hw-\(step).png"))
                        Capture.write(other.column, to: path.replacingOccurrences(of: ".png", with: "-hw-\(step)-content.png"))
                        report += "\(step): \(other.model.draft.model.displayName), \(other.model.target.hardwareTitle ?? "")\n"
                    }
                }
            case "socket-menu":
                // The menu of the first socket that has one (once the
                // window's shown the ROMs just added).
                await pause(1)
                if let bank = (0..<16).first(where: { controller.socketMenu($0) != nil }), let button = controller.socketMenu(bank) {
                    button.popup()
                    await pause(1)
                    if let popover = gtk_menu_button_get_popover(cast(button.widget)) {
                        let widget = Widget(cast(popover) as UnsafeMutablePointer<GtkWidget>)
                        report += "socket menu: bank \(bank), visible \(widget.isVisible), \(widget.width) x \(widget.height)\n"
                        Capture.write(widget, to: path.replacingOccurrences(of: ".png", with: "-hw-\(step).png"))
                    }
                    await capture("\(step)-window")
                    button.popdown()
                }
            case "station":
                // A network's station, on, then off.
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-hardware-selftest-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("Hardware.\(NetworkPackage.fileExtension)")
                guard (try? NetworkPackage.create(.bbcAndMaster, at: url)) != nil, let session = try? NetworkSession.session(for: url),
                      let station = session.project.stations.first(where: { $0.kind == .station && $0.setup?.model == .modelB }) else {
                    report += "\(step): no network\n"
                    continue
                }
                await pause(4)
                let ref = HardwareRef.station(network: url, node: station.id)
                HardwareExpansionsWindow.show(ref: ref)
                await pause(1)
                let key = "hardware-station-\(url.path)-\(station.id)"
                if let other = HardwareExpansionsWindow.controller(key) {
                    other.window.setDefaultSize(width: 760, height: 1000)
                    other.column.style("hw-capture")
                    other.model.draft.expansions = BBCMicro.Expansions(sidewaysRAM: .ram16)
                    await pause(1.5)
                    Capture.write(other.window, to: path.replacingOccurrences(of: ".png", with: "-hw-station-on.png"))
                    Capture.write(other.column, to: path.replacingOccurrences(of: ".png", with: "-hw-station-on-content.png"))
                    other.model.target.apply(other.model.draft)
                    await pause(3.5)
                    report += "station on: running \(other.model.running != nil), \(other.model.target.hardwareTitle ?? ""), module \(other.model.target.setup.expansions.sidewaysRAM.displayName), pending \(other.model.pending), network module \(session.project[station.id]?.setup?.expansions.sidewaysRAM.displayName ?? "?")\n"
                    session.powerOff(station.id)
                    await pause(1.5)
                    other.model.draft.videoNuLA = true
                    await pause(1)
                    Capture.write(other.window, to: path.replacingOccurrences(of: ".png", with: "-hw-station-off.png"))
                    other.model.target.apply(other.model.draft)
                    await pause(1)
                    report += "station off: running \(other.model.running != nil), pending \(other.model.pending), network NuLA \(session.project[station.id]?.setup?.videoNuLA == true)\n"
                    session.powerOn(station.id)
                    await pause(2.5)
                    let nula = (try? await session.controllers[station.id]?.host.performAsync { $0.machine.nula != nil }) ?? nil
                    report += "station on again with VideoNuLA: \(nula == true), window running \(other.model.running != nil)\n"
                    other.window.close()
                }
                session.powerOffAll()
                try? FileManager.default.removeItem(at: folder)
            case "empty-library":
                for rom in ROMLibrary.shared.roms { try? ROMLibrary.shared.remove(rom.id) }
                for saved in MachineConfigurations.shared.machines { try? MachineConfigurations.shared.remove(saved.id) }
                ROMLibraryWindow.show()
                MachineConfigurationsWindow.show()
                await pause(1)
                if let library = Windows.existing("rom-library") { await capture("library-empty", library) }
                if let configurations = Windows.existing("configurations") { await capture("configurations-empty", configurations) }
            default:
                report += "\(step): not a step\n"
            }
        }
        try? report.write(toFile: path.replacingOccurrences(of: ".png", with: "-hw.txt"), atomically: true, encoding: .utf8)
        Application.shared.quit()
    }
}
