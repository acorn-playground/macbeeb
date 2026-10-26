// A 5.25" floppy drive: spindle motor, head stepper, index sensor.
//
// A port of jsbeeb's disc-drive.js (Matt Godbolt et al., GPLv3), itself
// translated from beebjit by Chris Evans.
//
// The disc turns one 32-pulse word (64us at 300rpm) per rotation step. The
// controller that owns the drive supplies the time in microseconds and runs
// each step when `timer` comes due.

#if canImport(FoundationEssentials)
import FoundationEssentials
#if canImport(WASILibc)
import WASILibc
#endif
#else
import Foundation
#endif

public final class DiscDrive {
    /// For drive noises.
    public enum Event: Sendable, Equatable {
        case startSpinning
        case stopSpinning
        /// The head is about to take `steps` steps (signed), one every `stepMs`.
        case seekStart(steps: Int, stepMs: Int)
        /// The head stopped after `steps` of them.
        case seekEnd(steps: Int)
    }

    static let revolutionUs = 200_000.0
    /// scarybeasts' Chinon drive holds the index pulse for about 4ms.
    static let indexMs = 4.0
    /// Time constants of the spin-up and spin-down exponentials. A coasting
    /// disc stops at `leastSpeed` (about 2s after the motor stops), which is
    /// also the speed a restart picks up from.
    static let spinUpUs = 150_000.0
    static let spinDownUs = 500_000.0
    static let leastSpeed = 0.02
    static let atSpeed = 0.9999

    public let id: Int
    public private(set) var disc: Disc?
    /// The drive's own write-protect sense, as well as the disc's tab.
    public var writeProtectSwitch = false
    public var onEvent: ((Event) -> Void)?

    /// 2 for a 40-track drive (or an 80-track one switched to 40), which
    /// steps twice for each track the controller counts.
    public var tracksPerStep = 1 {
        didSet { precondition(tracksPerStep == 1 || tracksPerStep == 2, "Drives step one or two tracks") }
    }
    /// Where the head is over the 96tpi surface.
    public private(set) var track = 0
    public private(set) var isSideUpper = false
    /// In words; 3125 to a standard track.
    public private(set) var headPosition = 0
    /// Extra precision for MFM.
    var pulsePosition = 0
    var in32usMode = false
    public private(set) var spinning = false
    var seekSteps: Int?
    /// Speed (fraction of 300rpm) when the motor last started or stopped, and when.
    var speedThen = 0.0
    var speedTime: Int64 = 0
    var atFullSpeed = false

    /// When the next rotation step is due (us); `.max` when the disc is still.
    var timer = Int64.max
    var stepPulses = 32

    public init(id: Int) {
        self.id = id
    }

    // MARK: State

    /// Everything about the drive, including the disc in it (see
    /// `Disc.State` for its size), the head's angle and the spindle's speed.
    public struct State: Codable, Sendable, Equatable {
        fileprivate var disc: Disc.State?
        fileprivate var writeProtectSwitch: Bool
        fileprivate var tracksPerStep: Int
        fileprivate var track: Int
        fileprivate var isSideUpper: Bool
        fileprivate var headPosition: Int
        fileprivate var pulsePosition: Int
        fileprivate var in32usMode: Bool
        fileprivate var spinning: Bool
        fileprivate var seekSteps: Int?
        fileprivate var speedThen: Double
        fileprivate var speedTime: Int64
        fileprivate var atFullSpeed: Bool
        fileprivate var timer: Int64
        fileprivate var stepPulses: Int
    }

    public var state: State {
        State(disc: disc?.state, writeProtectSwitch: writeProtectSwitch, tracksPerStep: tracksPerStep,
              track: track, isSideUpper: isSideUpper, headPosition: headPosition, pulsePosition: pulsePosition,
              in32usMode: in32usMode, spinning: spinning, seekSteps: seekSteps, speedThen: speedThen,
              speedTime: speedTime, atFullSpeed: atFullSpeed, timer: timer, stepPulses: stepPulses)
    }

    /// Restores the drive and its disc. A saved disc goes back into the
    /// `Disc` already in the drive if there is one (keeping its
    /// `onTrackWritten`), or a new one; a saved empty drive ejects. Leaves
    /// `onEvent` as it is.
    public func restore(_ state: State) {
        if let discState = state.disc {
            if let disc {
                disc.restore(discState)
            } else {
                disc = Disc(state: discState)
            }
        } else {
            disc = nil
        }
        writeProtectSwitch = state.writeProtectSwitch
        tracksPerStep = state.tracksPerStep == 2 ? 2 : 1
        track = min(max(state.track, 0), IBMDiscFormat.tracksPerDisc - 1)
        isSideUpper = state.isSideUpper
        headPosition = min(max(state.headPosition, 0), Track.capacity - 1)
        pulsePosition = state.pulsePosition == 16 ? 16 : 0
        in32usMode = state.in32usMode
        spinning = state.spinning
        seekSteps = state.seekSteps
        speedThen = state.speedThen
        speedTime = state.speedTime
        atFullSpeed = state.atFullSpeed
        timer = state.timer
        stepPulses = state.stepPulses
    }

    /// Inserts (or with nil, ejects) a disc. Leaves the 40/80 switch
    /// following the disc's layout.
    public func insert(_ disc: Disc?) {
        checkTrackNeedsWrite()
        // Discs differ in track length, so the head keeps its angle.
        let fraction = positionFraction
        self.disc = disc
        positionFraction = fraction
        tracksPerStep = disc?.is40Track == true ? 2 : 1
    }

    public var writeProtected: Bool {
        writeProtectSwitch || disc?.writeProtected == true
    }

    /// The track the controller believes the head is on.
    public var logicalTrack: Int { track / tracksPerStep }

    public var trackLength: Int {
        disc?.trackLength(upper: isSideUpper, track: track) ?? IBMDiscFormat.bytesPerTrack
    }

    public var indexPulse: Bool {
        // With no disc the drive asserts index all the time. (The 8271 needs
        // over 0.5us; drives give milliseconds.)
        guard disc != nil else { return true }
        return Double(headPosition) < Double(trackLength) * Self.indexMs / (Self.revolutionUs / 1000)
    }

    var positionFraction: Double {
        get { (Double(headPosition) + Double(pulsePosition) / 32) / Double(trackLength) }
        set {
            headPosition = Int(Double(trackLength) * newValue)
            pulsePosition = 0
        }
    }

    var positionTime: Int { Int(positionFraction * Self.revolutionUs) }

    /// Speed as a fraction of 300rpm.
    func speed(at now: Int64) -> Double {
        if atFullSpeed { return 1 }
        let elapsed = Double(now - speedTime)
        let speed = spinning
            ? 1 - (1 - speedThen) * exp(-elapsed / Self.spinUpUs)
            : speedThen * exp(-elapsed / Self.spinDownUs)
        if speed > Self.atSpeed {
            if spinning { atFullSpeed = true }
            return 1
        }
        return max(Self.leastSpeed, speed)
    }

    private func noteSpeed(_ now: Int64) {
        speedThen = speed(at: now)
        speedTime = now
        atFullSpeed = false
    }

    func startSpinning(at now: Int64) {
        guard !spinning else { return }
        noteSpeed(now)
        spinning = true
        onEvent?(.startSpinning)
        if timer == .max { timer = now + 1 }
    }

    func stopSpinning(at now: Int64) {
        guard spinning else { return }
        noteSpeed(now)
        spinning = false
        onEvent?(.stopSpinning)
    }

    /// First half of a rotation step: the pulses under the head, if the
    /// motor is on (a coasting disc turns but nothing reads it).
    func rotationPulses(at now: Int64) -> (pulses: UInt32, count: Int)? {
        timer = .max
        stepPulses = pulsePosition == 16 || in32usMode ? 16 : 32
        guard spinning else { return nil }
        var pulses = disc?.readPulses(upper: isSideUpper, track: track, position: headPosition) ?? 0
        if stepPulses == 16 {
            if pulsePosition == 0 { pulses >>= 16 }
            pulses &= 0xFFFF
        }
        // An empty patch of disc makes the head amplifier hunt for a signal
        // in the noise: inconsistent but deterministic weak bits.
        if pulses == 0 { pulses = quasiRandomPulses(now) }
        return (pulses, stepPulses)
    }

    /// Second half: moves the disc on and schedules the next step.
    func advanceRotation(at now: Int64) {
        let thisTime = positionTime
        if stepPulses == 16 && pulsePosition == 0 {
            pulsePosition = 16
        } else {
            pulsePosition = 0
            headPosition += 1
        }
        let nextTime = positionTime
        if headPosition >= trackLength {
            headPosition = 0
            checkTrackNeedsWrite()
        }
        let speed = speed(at: now)
        if spinning || speed > Self.leastSpeed {
            timer = now + Int64((Double(nextTime - thisTime) / speed).rounded(.toNearestOrAwayFromZero))
        }
    }

    func quasiRandomPulses(_ now: Int64) -> UInt32 {
        let t = UInt32(truncatingIfNeeded: now)
        let data = UInt8(truncatingIfNeeded: t ^ t >> 8 ^ t >> 16 ^ t >> 24)
        return IBMDiscFormat.fmTo2usPulses(clocks: 0xFF, data: data)
    }

    func selectSide(upper: Bool) {
        checkTrackNeedsWrite()
        guard upper != isSideUpper else { return }
        let fraction = positionFraction
        isSideUpper = upper
        positionFraction = fraction
    }

    func writePulses(_ pulses: UInt32) {
        guard let disc else { return }
        // Drives have their own write-protect failsafe.
        guard !writeProtected else { return }
        var pulses = pulses
        if in32usMode {
            let existing = disc.readPulses(upper: isSideUpper, track: track, position: headPosition)
            pulses = pulsePosition == 0 ? existing & 0x0000_FFFF | pulses << 16 : existing & 0xFFFF_0000 | pulses & 0xFFFF
        }
        disc.writePulses(upper: isSideUpper, track: track, position: headPosition, pulses)
    }

    func set32usMode(_ doubleDensity: Bool) {
        in32usMode = doubleDensity
    }

    /// Steps the head one of the controller's tracks; `delta` is 1 or -1.
    func seekOneTrack(_ delta: Int) {
        let from = track
        selectTrack(track + delta * tracksPerStep)
        if seekSteps != nil && track != from { seekSteps! += 1 }
    }

    /// The controller is about to seek `delta` of its tracks. Informational.
    func notifySeekAmount(_ delta: Int, stepMs: Int) {
        // None past either end of the surface; a last one onto the edge though it falls short.
        let lastTrack = IBMDiscFormat.tracksPerDisc - tracksPerStep
        let target = min(lastTrack, max(0, track + delta * tracksPerStep))
        let distance = abs(target - track)
        let steps = delta.signum() * ((distance + tracksPerStep - 1) / tracksPerStep)
        seekSteps = steps != 0 ? 0 : nil
        if steps != 0 { onEvent?(.seekStart(steps: steps, stepMs: stepMs)) }
    }

    func notifySeekEnd() {
        guard let steps = seekSteps else { return }
        seekSteps = nil
        onEvent?(.seekEnd(steps: steps))
    }

    private func selectTrack(_ newTrack: Int) {
        checkTrackNeedsWrite()
        let fraction = positionFraction
        track = min(max(newTrack, 0), IBMDiscFormat.tracksPerDisc - tracksPerStep)
        positionFraction = fraction
    }

    private func checkTrackNeedsWrite() {
        guard let disc, let written = disc.flushWrites() else { return }
        // A 48tpi head writes most of its band but not as far as the next
        // 96tpi track, which is left blank in the guard band.
        if tracksPerStep == 2 { disc.eraseTrack(upper: written.upper, track: written.track ^ 1) }
    }
}

extension BBCMicro {
    /// A DFS disc's files were changed from outside (MacBeeb's Disc
    /// Contents, or the Network Studio adding files to a file server): if
    /// DFS has the disc's old catalogue cached (at &0E00, its two sectors),
    /// it's given the new one, as it would have after reading the disc
    /// again. The Model B's 8271 can't tell DFS a disc's been changed, so
    /// it would otherwise go on using the old one until it next read it.
    /// Anything else at &0E00 is left alone. Returns whether it did.
    @discardableResult
    public func refreshCachedCatalogue(old: [UInt8], new: [UInt8]) -> Bool {
        guard old.count >= 512, new.count >= 512, old[0..<512] != new[0..<512] else { return false }
        for i in 0..<512 where peek(UInt16(0x0E00 + i)) != old[i] {
            return false
        }
        for i in 0..<512 {
            poke(UInt16(0x0E00 + i), new[i])
        }
        return true
    }
}
