import BeebCore
import Foundation

/// A step of what's typed into a machine when it's switched on. Times are
/// the machine's own (emulated) seconds, so a network that runs slow still
/// gets there.
public enum StartupStep: Codable, Sendable, Equatable {
    /// Waits until a file server on the network (here, or in the Internet
    /// room it's in) is ready.
    case waitForServer
    /// Types text, as at the keyboard ("\n" is Return).
    case type(String)
    /// Holds a key (named as `BeebKey.named` knows it) for long enough that
    /// a game scanning the keyboard sees it, then lets go.
    case press(String)
    /// Waits for a line on the screen (text the OS printed) to start with
    /// one of these, for up to `timeout` seconds, then carries on either
    /// way. (The start of a line: a program being typed in may have the
    /// same words further along one.)
    case waitForText([String], timeout: Double)
    /// Runs these steps if a line on the screen starts with this now.
    case ifShowing(String, [StartupStep])
    case pressBreak
    case wait(Double)
    /// Waits until nothing's gone to or from the machine on the network for
    /// `seconds` (it's finished loading), for up to `timeout`.
    case waitForQuiet(Double, timeout: Double)

    /// How long `press` holds a key: Elite scans the keyboard once a frame
    /// of its own, which can be slower than the OS's 10ms.
    public static let pressSeconds = 0.3
}

/// Plays a startup script into a machine, a little at a time: call
/// `advance` every so often (every 10-100ms of its time) on the machine's
/// thread. Waits are in the machine's time.
public final class StartupScriptRunner: @unchecked Sendable {
    private var steps: [StartupStep]
    /// The machine's clock when the current step started (nil: not yet).
    private var started: UInt64?
    /// Whether the current step's typing has been handed to the machine.
    private var typed = false
    /// A held key, and when to let go of it.
    private var held: (key: BeebKey, until: UInt64)?

    public init(_ steps: [StartupStep]) {
        self.steps = steps
    }

    public var isFinished: Bool { steps.isEmpty && held == nil }

    /// Does what's due; returns whether the script's finished.
    /// `serverReady`: whether a file server's ready yet.
    @discardableResult
    public func advance(_ machine: BBCMicro, serverReady: Bool) -> Bool {
        let now = machine.cycles
        func seconds(_ s: Double) -> UInt64 { UInt64(s * 2_000_000) }
        if let held {
            guard now >= held.until else { return false }
            machine.setKey(held.key, down: false)
            self.held = nil
            // A gap before the next key, as a typist leaves.
            started = now
            steps.insert(.wait(StartupStep.pressSeconds), at: 0)
            return false
        }
        while let step = steps.first {
            let start = started ?? now
            started = start
            switch step {
            case .waitForServer:
                guard serverReady else { return false }
            case .type(let text):
                if !typed {
                    machine.type(text)
                    typed = true
                    return false
                }
                guard !machine.isTyping else { return false }
                typed = false
            case .press(let name):
                steps.removeFirst()
                started = nil
                if let key = BeebKey.named(name) {
                    machine.setKey(key, down: true)
                    held = (key, now + seconds(StartupStep.pressSeconds))
                }
                return false
            case .waitForText(let texts, let timeout):
                let showing = texts.contains { Self.showing($0, on: machine) }
                guard showing || now >= start + seconds(timeout) else { return false }
            case .ifShowing(let text, let then):
                steps.removeFirst()
                started = nil
                if Self.showing(text, on: machine) {
                    steps.insert(contentsOf: then, at: 0)
                }
                continue
            case .pressBreak:
                machine.pressBreak()
            case .wait(let duration):
                guard now >= start + seconds(duration) else { return false }
            case .waitForQuiet(let quiet, let timeout):
                let last = max(start, machine.econet?.lastTransmitted ?? 0, machine.econet?.lastAddressed ?? 0)
                guard now >= last + seconds(quiet) || now >= start + seconds(timeout) else { return false }
            }
            steps.removeFirst()
            started = nil
        }
        return isFinished
    }

    static func showing(_ text: String, on machine: BBCMicro) -> Bool {
        machine.screenText().contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(text) }
    }
}
