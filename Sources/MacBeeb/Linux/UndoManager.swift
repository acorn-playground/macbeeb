import Foundation

/// Foundation's UndoManager, which Foundation on Linux hasn't got: what the
/// shared code registers (a closure to undo with, and its name), and Undo
/// and Redo. What's registered while undoing is what Redo does, as with
/// Foundation's — and also what's registered later by a task the undoing
/// started (the disc contents' changes wait for the drive, then register
/// their own undoing), so Redo works for those too.
@MainActor
final class UndoManager {
    private struct Step {
        var name: String
        var perform: @MainActor () -> Void
    }

    /// Undoing or redoing, for registrations from tasks a step starts (which
    /// inherit it).
    private enum Phase: Sendable {
        case undoing, redoing
        @TaskLocal static var current: Phase?
    }

    private var undoStack: [Step] = []
    private var redoStack: [Step] = []
    private var undoing = false
    private var redoing = false
    /// The name the next registration gets.
    private var pendingName = ""
    /// Where the last registration went, for setActionName to name it.
    private var lastWentToRedo = false

    /// Counts changes, for menus to follow.
    private(set) var changes = 0

    func registerUndo<Target: AnyObject>(withTarget target: Target, handler: @escaping @MainActor (Target) -> Void) {
        let step = Step(name: pendingName) { [weak target] in
            if let target { handler(target) }
        }
        let phase = Phase.current ?? (undoing ? .undoing : redoing ? .redoing : nil)
        switch phase {
        case .undoing:
            redoStack.append(step)
        case .redoing:
            undoStack.append(step)
        case nil:
            undoStack.append(step)
            redoStack.removeAll()
        }
        lastWentToRedo = phase == .undoing
        changes += 1
    }

    func setActionName(_ name: String) {
        pendingName = name
        if lastWentToRedo, !redoStack.isEmpty {
            redoStack[redoStack.count - 1].name = name
        } else if !lastWentToRedo, !undoStack.isEmpty {
            undoStack[undoStack.count - 1].name = name
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoActionName: String { undoStack.last?.name ?? "" }
    var redoActionName: String { redoStack.last?.name ?? "" }

    func undo() {
        guard let step = undoStack.popLast() else { return }
        undoing = true
        pendingName = step.name
        Phase.$current.withValue(.undoing) { step.perform() }
        undoing = false
        changes += 1
    }

    func redo() {
        guard let step = redoStack.popLast() else { return }
        redoing = true
        pendingName = step.name
        Phase.$current.withValue(.redoing) { step.perform() }
        redoing = false
        changes += 1
    }

    func removeAllActions() {
        undoStack.removeAll()
        redoStack.removeAll()
        changes += 1
    }
}
