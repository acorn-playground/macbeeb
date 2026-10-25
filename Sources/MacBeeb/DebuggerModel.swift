import BeebCore
import BeebHost
import Foundation
import Observation

/// The debugger window's view of one machine.
@MainActor
@Observable
final class DebuggerModel {
    private let host: EmulatorHost
    private(set) var snapshot: DebugSnapshot?
    /// The memory view's bytes as of the last stop, to show changes.
    private(set) var previousMemory: [UInt8?] = []
    var view = DebugView() {
        didSet { if view != oldValue { refresh() } }
    }
    /// The last error from a command, shown in the window.
    var message: String?
    /// True while the debugger window is on screen.
    var isVisible = false {
        didSet {
            host.setInspecting(isVisible)
            if isVisible { refresh() }
        }
    }
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastStop: StopReason?

    init(host: EmulatorHost) {
        self.host = host
        // While running, refresh a few times a second.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                if self.host.debugStop == nil || self.host.debugStop != self.lastStop {
                    self.refresh()
                }
            }
        }
    }

    var isStopped: Bool { snapshot?.stopReason != nil }
    var cpu: DebugCPU { view.cpu }

    /// Fetches a new snapshot from the emulation thread.
    func refresh() {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        let view = self.view
        Task {
            let result = try? await host.performAsync { session in
                DebugSnapshot(machine: session.machine, view: view)
            }
            refreshing = false
            if let result {
                if result.stopReason != nil && result.stopReason != lastStop, let old = snapshot,
                   old.view.memorySpace == result.view.memorySpace, old.view.memoryAddress == result.view.memoryAddress {
                    previousMemory = old.memory
                }
                // A BASIC stop shows the program, and any other stop the
                // machine code.
                if let reason = result.stopReason, reason != lastStop, reason.isBasic != self.view.basic {
                    self.view.basic = reason.isBasic
                }
                lastStop = result.stopReason
                snapshot = result
            }
            if refreshAgain {
                refreshAgain = false
                refresh()
            }
        }
    }

    /// Runs `body` on the emulation thread, then refreshes.
    private func command(_ body: @escaping @Sendable (BBCMicro) throws -> Void) {
        Task {
            do {
                try await host.performAsync { session in try body(session.machine) }
                message = nil
            } catch {
                message = "\(error)"
            }
            refresh()
        }
    }

    // MARK: Running

    func pauseOrContinue() {
        if isStopped {
            command { $0.debugger.resume() }
        } else {
            command { $0.debugger.requestStop() }
        }
    }

    func run(_ runCommand: RunCommand) {
        let cpu = view.cpu
        if runCommand == .stepCycle {
            command { m in
                m.debugger.resume()
                m.run(cycles: 1)
                if m.debugger.stopReason == nil {
                    m.debugger.requestStop()
                }
            }
        } else {
            command { $0.debugger.begin(runCommand, cpu: cpu) }
        }
    }

    func stepBack() {
        let cpu = view.cpu
        command { try $0.debugger.stepBack(cpu) }
    }

    func reverseContinue() {
        command { try $0.debugger.reverseContinue() }
    }

    // MARK: Breakpoints

    func toggleBreakpoint(at address: UInt16) {
        let cpu = view.cpu
        command { m in
            if let existing = m.debugger.breakpoints.first(where: { $0.cpu == cpu && $0.kind == .execute && $0.start == address && $0.end == address }) {
                m.debugger.remove(id: existing.id)
            } else {
                try m.debugger.add(Breakpoint(cpu: cpu, start: address))
            }
        }
    }

    func addBreakpoint(_ breakpoint: Breakpoint) {
        command { try $0.debugger.add(breakpoint) }
    }

    func updateBreakpoint(_ breakpoint: Breakpoint) {
        command { try $0.debugger.update(breakpoint) }
    }

    func removeBreakpoint(id: Int) {
        command { $0.debugger.remove(id: id) }
    }

    func removeAllBreakpoints() {
        command { $0.debugger.removeAllBreakpoints() }
    }

    // MARK: BASIC

    var basic: BasicDebugSnapshot? { snapshot?.basic }

    /// A line the listing should scroll to (`serial` so the same line
    /// can be asked for again).
    struct ScrollRequest: Equatable {
        var line: Int
        var serial: Int
    }

    private(set) var basicScrollRequest: ScrollRequest?

    func showBasicLine(_ line: Int) {
        basicScrollRequest = ScrollRequest(line: line, serial: (basicScrollRequest?.serial ?? 0) + 1)
    }

    /// In BASIC, Pause stops at the next statement (so it's somewhere in
    /// the program).
    func basicPauseOrContinue() {
        if isStopped {
            command { $0.debugger.resume() }
        } else {
            command { $0.debugger.begin(basic: .into) }
        }
    }

    func basicStep(_ kind: BasicStep) {
        command { $0.debugger.begin(basic: kind) }
    }

    /// Adds a breakpoint on the line, or removes the line's.
    func toggleBasicBreakpoint(line: Int) {
        command { m in
            let basic = m.debugger.basic
            let existing = basic.breakpoints.filter { $0.line == line }
            if existing.isEmpty {
                try basic.add(BasicBreakpoint(line: line))
            } else {
                for b in existing { basic.remove(id: b.id) }
            }
        }
    }

    func addBasicBreakpoint(_ breakpoint: BasicBreakpoint) {
        command { try $0.debugger.basic.add(breakpoint) }
    }

    func updateBasicBreakpoint(_ breakpoint: BasicBreakpoint) {
        command { try $0.debugger.basic.update(breakpoint) }
    }

    func removeBasicBreakpoint(id: Int) {
        command { $0.debugger.basic.remove(id: id) }
    }

    func removeAllBasicBreakpoints() {
        command { $0.debugger.basic.removeAllBreakpoints() }
    }

    func setBasicErrorStop(_ mode: BasicDebugger.ErrorStop) {
        command { $0.debugger.basic.errorStop = mode }
    }

    /// Sets a variable (or an array element) to a BASIC expression's value.
    func setBasicVariable(_ name: String, indices: [Int]? = nil, to expression: String) {
        let cpu = basic?.cpu
        command { try $0.debugger.basic.set(name, indices: indices, to: expression, cpu: cpu) }
    }

    func toggleBasicArray(_ name: String) {
        if view.basicExpanded.contains(name) {
            view.basicExpanded.remove(name)
        } else {
            view.basicExpanded.insert(name)
        }
    }

    func addBasicWatch(_ expression: String) {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !view.basicWatches.contains(trimmed) else { return }
        view.basicWatches.append(trimmed)
    }

    func removeBasicWatch(_ expression: String) {
        view.basicWatches.removeAll { $0 == expression }
    }

    // MARK: State

    func setRegister(_ name: String, to value: Int) {
        let cpu = view.cpu
        command { try $0.setRegister(name, cpu: cpu, to: value) }
    }

    func write(_ value: UInt8, at address: Int) {
        let space = view.memorySpace
        command { m in
            guard m.debugWrite(space, address, value) else {
                throw DebuggerError("can't write &\(String(address, radix: 16, uppercase: true)) there")
            }
        }
    }

    /// Loads ld65 debug info or a label file for the current CPU.
    func loadSymbols(_ url: URL) {
        let cpu = view.cpu
        command { m in
            let table = try SymbolTable.load(path: url.path)
            m.debugger.addSymbols(table, cpu: cpu)
        }
    }

    func setProfiling(_ on: Bool) {
        command { m in
            if on { m.debugger.startProfiling() } else { m.debugger.stopProfiling() }
        }
    }

    func setTracing(_ on: Bool) {
        command { $0.debugger.setTracing(capacity: on ? 100_000 : 0) }
    }

    /// A number, or else an expression evaluated now.
    func address(_ text: String) async -> Int? {
        if let n = parseNumber(text) {
            return n
        }
        return await evaluate(text)
    }

    /// Evaluates an address expression (registers, memory, symbols) now.
    func evaluate(_ text: String) async -> Int? {
        let cpu = view.cpu
        return try? await host.performAsync { session in
            try DebugExpression(text).evaluate(session.machine.debugger.expressionContext(cpu))
        }
    }
}

struct DebuggerError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
