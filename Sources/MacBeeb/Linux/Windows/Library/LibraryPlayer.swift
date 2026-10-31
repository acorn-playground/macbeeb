import BeebLibrary
import CGtk
import Foundation

/// Starts library games and restores snapshots in the machine in front
/// (or a new one), asking before taking over a machine that's busy. (The
/// Mac's Player.)
@MainActor
enum LibraryPlayer {
    static func play(_ game: CuratedGame, record: InstalledGame) {
        Task {
            let url: URL
            do {
                url = try await ClassicsLibrary.shared.library.prepareWorkingCopy(record)
            } catch {
                Platform.showError(error)
                return
            }
            run(owner: record.libraryID, confirm: playConfirmation(game.title)) {
                $0.play(game, disc: url, record: record)
            }
        }
    }

    static func play(_ game: PersonalGame) {
        guard let url = ClassicsLibrary.shared.myGames.discURL(game) else { return }
        run(owner: game.id, confirm: playConfirmation(game.title)) { $0.play(game, disc: url) }
    }

    static func restore(_ snapshot: SnapshotManifest, title: String) {
        run(owner: snapshot.owner, confirm: { machine in
            (title: "Restore \(title)?",
             detail: "The machine is replaced by the snapshot, and “\(machine.discNames[0] ?? "")” is taken out. Anything unsaved there is lost.",
             button: "Restore")
        }) { machine in
            machine.quickLoad(snapshot)
            NotificationCenter.default.post(name: MachineWindowEvent.bringToFront, object: machine.host)
        }
    }

    private typealias Confirmation = @MainActor (MachineController) -> (title: String, detail: String, button: String)

    private static func playConfirmation(_ title: String) -> Confirmation {
        { machine in
            (title: "Play \(title)?",
             detail: "The machine restarts with \(title), replacing “\(machine.discNames[0] ?? "")”. Anything unsaved there is lost (Quick Save, Alt+Shift+F6, keeps it).",
             button: "Play")
        }
    }

    /// Runs `launch` in the machine in front, after asking if it's playing
    /// something else, or in a new machine window if there's none.
    private static func run(owner: UUID, confirm: Confirmation, _ launch: @escaping @MainActor (MachineController) -> Void) {
        guard let machine = MachineController.frontmost, MachineWindow.existing(for: machine) != nil else {
            let window = MachineWindow.openNew()
            MachineController.frontmost = window.machine
            launch(window.machine)
            return
        }
        guard machine.isPlayingSomething && machine.snapshotOwner?.id != owner else {
            launch(machine)
            return
        }
        let question = confirm(machine)
        Platform.confirm(title: question.title, message: question.detail, action: question.button) { confirmed in
            if confirmed { launch(machine) }
        }
    }
}
