// WD1770/WD1772 floppy disc controller, with the drive control latch of the
// boards that carry it on the BBC.
//
// A port of jsbeeb's wd-fdc.js (Matt Godbolt et al., GPLv3), itself
// translated from beebjit by Chris Evans (https://github.com/scarybeasts/beebjit).
//
// jsbeeb runs this from a scheduler of timed callbacks. Here `tick()` runs
// once per microsecond and fires whatever has come due: each drive's
// rotation step (an FM byte every 64us, or an MFM byte every 32us; see
// DiscDrive), and the controller's one timer (step, settle, the 32us before
// a command completes). With nothing due, a tick is an increment and a compare.

public final class WD1770 {
    public enum Variant: String, Sendable, Codable {
        case wd1770
        /// Faster step rates (the Master Compact's).
        case wd1772
    }

    /// How a board's drive control latch drives the controller's lines. Both
    /// latches are write only (reads see the stale data bus).
    public enum ControlLayout: Sendable {
        /// The Acorn 1770 board for the Model B: latch at &FE80, controller
        /// at &FE84. Bit 0 selects drive 0, 1 drive 1, 2 the upper side; 3
        /// is single density, 5 clear holds the controller in reset.
        case acorn1770
        /// The Master 128: latch at &FE24, controller at &FE28. Bit 0 selects
        /// drive 0, 1 drive 1; 2 clear holds the controller in reset; 4
        /// selects the upper side, 5 is single density. (BeebEm takes bit 3
        /// for drive 2, which isn't wired here.)
        case master128
        /// Watford DDB2: bit 0 single density, 1 the upper side, 2 drive 1
        /// (else drive 0); never in reset. Readable.
        case watfordDDB2
        /// Watford DDB3: as the Acorn board, but readable.
        case watfordDDB3
        /// Opus (latch at &FE84, controller at &FE80): bit 0 drive 1 (else
        /// 0), 1 the upper side, 6 double density; never in reset. Readable.
        case opus

        /// Whether reading the latch gives it back (others give the stale
        /// bus).
        public var isReadable: Bool {
            switch self {
            case .acorn1770, .master128: false
            case .watfordDDB2, .watfordDDB3, .opus: true
            }
        }
    }

    /// The controller's lines, in the Acorn board's layout.
    private enum Control {
        static let notReset: UInt8 = 0x20
        static let singleDensity: UInt8 = 0x08
        static let side: UInt8 = 0x04
        static let drive1: UInt8 = 0x02
        static let drive0: UInt8 = 0x01
    }

    public enum Status {
        public static let motorOn: UInt8 = 0x80
        public static let writeProtected: UInt8 = 0x40
        public static let typeISpinUpDone: UInt8 = 0x20
        public static let deletedMark: UInt8 = 0x20
        public static let recordNotFound: UInt8 = 0x10
        public static let crcError: UInt8 = 0x08
        public static let typeITrack0: UInt8 = 0x04
        public static let lostByte: UInt8 = 0x04
        public static let typeIIndex: UInt8 = 0x02
        public static let drq: UInt8 = 0x02
        public static let busy: UInt8 = 0x01
    }

    private enum Command {
        static let restore: UInt8 = 0x00
        static let seek: UInt8 = 0x10
        static let stepNoUpdate: UInt8 = 0x20
        static let stepWithUpdate: UInt8 = 0x30
        static let stepInNoUpdate: UInt8 = 0x40
        static let stepInWithUpdate: UInt8 = 0x50
        static let stepOutNoUpdate: UInt8 = 0x60
        static let stepOutWithUpdate: UInt8 = 0x70
        static let readSector: UInt8 = 0x80
        static let readSectorMulti: UInt8 = 0x90
        static let writeSector: UInt8 = 0xA0
        static let writeSectorMulti: UInt8 = 0xB0
        static let readAddress: UInt8 = 0xC0
        static let forceInterrupt: UInt8 = 0xD0
        static let readTrack: UInt8 = 0xE0
        static let writeTrack: UInt8 = 0xF0
    }

    private enum CommandBits {
        static let typeIIMulti: UInt8 = 0x10
        static let disableSpinUp: UInt8 = 0x08
        static let typeIVerify: UInt8 = 0x04
        static let typeIIorIIISettle: UInt8 = 0x04
        static let typeIIDeleted: UInt8 = 0x01
    }

    private enum ForceInterruptBits {
        static let indexPulse: UInt8 = 0x04
        static let immediate: UInt8 = 0x08
    }

    /// The type I bits that follow the drive's lines. Write protect is
    /// polled like track 0 after a type I command (Jean Louis-Guerin's
    /// WD1772 specification, status register summary, note 4).
    private static let typeIPolledStatus = Status.typeITrack0 | Status.typeIIndex | Status.writeProtected

    private static let fmIndexMark: UInt8 = 0xFC

    /// The datasheet figures. In jsbeeb #1225, 30ms reproduces the sectors a
    /// real Master 128 misses, and 15ms doesn't.
    private static let wd1770HeadSettleMs = 30
    private static let wd1772HeadSettleMs = 15

    private static let doneDelayUs = 32

    fileprivate enum Phase: UInt8, Codable {
        case idle, timerWait, spinUpWait, waitIndex, searchID, inID, searchData, inData, inReadTrack
        case writeSectorDelay, writeSectorLeadInFM, writeSectorLeadInMFM, writeSectorMarkerFM
        case writeSectorMarkerMFM, writeSectorBody, writeTrackSetup, inWriteTrack, checkMulti, done
    }

    fileprivate enum TimerState: UInt8, Codable { case none, settle, seek, done, verifySettle }

    public let variant: Variant
    public let drives: [DiscDrive]

    /// The interrupt request output: a command has finished.
    public private(set) var intrq = false
    /// The data request output: the data register wants reading or writing.
    public private(set) var drq = false
    /// Both boards drive the 6502's NMI from DRQ or INTRQ.
    public private(set) var nmi = false

    /// Microseconds since power on.
    public private(set) var time: Int64 = 0
    private var nextEvent = Int64.max
    private var timerAt = Int64.max

    /// The latch, in the Acorn board's layout.
    private var control: UInt8 = 0
    private var statusRegister: UInt8 = 0
    private var trackRegister: UInt8 = 0
    private var sectorRegister: UInt8 = 0
    private var dataRegister: UInt8 = 0
    private var doRaiseIntRq = false

    private var currentDrive: DiscDrive?
    private var isIndexPulse = false
    private var isInterruptOnIndexPulse = false
    private var isWriteTrackCRCSecondByte = false
    private var command: UInt8 = 0
    private var commandType = 0
    private var isCommandSettle = false
    private var isCommandWrite = false
    private var isCommandVerify = false
    private var isCommandMulti = false
    private var isCommandDeleted = false
    private var commandStepRateMs = 0
    /// For STEP, which goes the way the last step went.
    private var lastStepDirection = 1

    private var phase = Phase.idle
    private var timerState = TimerState.none
    private var stateCount = 0
    private var indexPulseCount = 0
    private var markDetector: UInt64 = 0
    private var dataShifter: UInt32 = 0
    private var dataShiftCount = 0
    private var deliverData: UInt8 = 0
    private var deliverIsMarker = false
    private var crc: UInt16 = 0
    private var onDiscTrack: UInt8 = 0
    private var onDiscSector: UInt8 = 0
    private var onDiscLength = 0
    private var onDiscCRC: UInt16 = 0
    private var lastMFMBit = false

    public init(variant: Variant = .wd1770, drives: [DiscDrive] = [DiscDrive(id: 0), DiscDrive(id: 1)]) {
        precondition(drives.count == 2)
        self.variant = variant
        self.drives = drives
        powerOnReset()
    }

    // MARK: Clock

    /// Advances 1us.
    @inline(__always)
    public func tick() {
        time &+= 1
        if time >= nextEvent { runDueEvents() }
    }

    private func runDueEvents() {
        while true {
            if timerAt <= time {
                timerAt = .max
                timerFired()
            } else if drives[0].timer <= time {
                rotate(drives[0])
            } else if drives[1].timer <= time {
                rotate(drives[1])
            } else {
                break
            }
        }
        updateNextEvent()
    }

    private func updateNextEvent() {
        nextEvent = min(timerAt, drives[0].timer, drives[1].timer)
    }

    private func rotate(_ drive: DiscDrive) {
        if let read = drive.rotationPulses(at: time), drive === currentDrive, statusRegister & Status.motorOn != 0 {
            pulsesReceived(read.pulses, count: read.count)
        }
        drive.advanceRotation(at: time)
    }

    // MARK: Reset

    /// The reset line: spins down, clears status and interrupts, and holds
    /// the sector register at 1 (track and data are left alone).
    public func reset() {
        setControl(0)
        updateNextEvent()
    }

    public func powerOnReset() {
        reset()
        // The reset line doesn't seem to affect the track or data registers.
        trackRegister = 0
        dataRegister = 0
    }

    // MARK: Registers

    /// Reads a register: 0 status, 1 track, 2 sector, 3 data.
    public func read(_ register: Int) -> UInt8 {
        let value = peek(register)
        switch register & 3 {
        case 0:
            // Reading status clears INTRQ.
            setIntRq(false)
        case 3:
            if commandType == 2 || commandType == 3 { setDrq(false) }
        default:
            break
        }
        return value
    }

    /// What `read` would return, without clearing INTRQ or DRQ.
    public func peek(_ register: Int) -> UInt8 {
        switch register & 3 {
        case 0: return statusRegister
        case 1: return trackRegister
        case 2: return sectorRegister
        default: return dataRegister
        }
    }

    /// Writes a register: 0 command, 1 track, 2 sector, 3 data.
    public func write(_ register: Int, _ value: UInt8) {
        switch register & 3 {
        case 0:
            // Commands are ignored in reset.
            if !isReset { doCommand(value) }
        case 1:
            trackRegister = value
        case 2:
            // As is the sector register (though not track and data).
            if !isReset { sectorRegister = value }
        default:
            if commandType == 2 || commandType == 3 { setDrq(false) }
            dataRegister = value
        }
        updateNextEvent()
    }

    /// Writes the board's drive control latch.
    public func writeControl(_ value: UInt8, layout: ControlLayout) {
        latch = value
        setControl(Self.controlLines(value, layout: layout))
        updateNextEvent()
    }

    static func controlLines(_ value: UInt8, layout: ControlLayout) -> UInt8 {
        switch layout {
        case .acorn1770:
            return value & (Control.notReset | Control.singleDensity | Control.side | Control.drive1 | Control.drive0)
        case .master128:
            var lines: UInt8 = 0
            if value & 0x04 != 0 { lines |= Control.notReset }
            if value & 0x01 != 0 { lines |= Control.drive0 }
            if value & 0x02 != 0 { lines |= Control.drive1 }
            if value & 0x10 != 0 { lines |= Control.side }
            if value & 0x20 != 0 { lines |= Control.singleDensity }
            return lines
        case .watfordDDB2:
            var lines = Control.notReset | (value & 0x04 != 0 ? Control.drive1 : Control.drive0)
            if value & 0x01 != 0 { lines |= Control.singleDensity }
            if value & 0x02 != 0 { lines |= Control.side }
            return lines
        case .watfordDDB3:
            return controlLines(value, layout: .acorn1770)
        case .opus:
            var lines = Control.notReset | (value & 0x01 != 0 ? Control.drive1 : Control.drive0)
            if value & 0x40 == 0 { lines |= Control.singleDensity }
            if value & 0x02 != 0 { lines |= Control.side }
            return lines
        }
    }

    /// The latch as last written, for the boards that can read it back.
    public private(set) var latch: UInt8 = 0

    /// The selected drive (drive 0 if the latch selects both), if any.
    public var selectedDrive: Int? {
        control & Control.drive0 != 0 ? 0 : control & Control.drive1 != 0 ? 1 : nil
    }

    public var isDoubleDensity: Bool { control & Control.singleDensity == 0 }
    public var isSideUpper: Bool { control & Control.side != 0 }
    public var isReset: Bool { control & Control.notReset == 0 }

    /// Each drive's activity light: its select line, gated by the motor.
    public func driveLight(_ drive: Int) -> Bool {
        drives[drive].spinning && drives[drive] === currentDrive
    }

    // MARK: Interrupts

    private func updateNMI() {
        nmi = drq || intrq
    }

    private func setIntRq(_ level: Bool) {
        intrq = level
        updateNMI()
    }

    private func setDrq(_ level: Bool) {
        drq = level
        if level {
            if statusRegister & Status.drq != 0 { statusRegister |= Status.lostByte }
            statusRegister |= Status.drq
        } else {
            statusRegister &= ~Status.drq
        }
        updateNMI()
    }

    // MARK: Commands

    private func doCommand(_ value: UInt8) {
        let command = value & 0xF0
        if command == Command.forceInterrupt {
            handleForceInterrupt(value)
            return
        }
        // Whether a command does anything when busy seems to depend on the
        // current command, the new one and where the state machine is.
        // jsbeeb ignores it.
        guard statusRegister & Status.busy == 0 else { return }

        self.command = command
        isCommandSettle = false
        isCommandWrite = false
        isCommandVerify = false
        isCommandMulti = false
        isCommandDeleted = false
        isInterruptOnIndexPulse = false
        isWriteTrackCRCSecondByte = false

        switch command {
        case Command.restore...Command.stepOutWithUpdate:
            commandType = 1
            isCommandVerify = value & CommandBits.typeIVerify != 0
            commandStepRateMs = stepRateMs(value)
        case Command.readSector...Command.writeSectorMulti:
            commandType = 2
            isCommandMulti = value & CommandBits.typeIIMulti != 0
        default:
            // Read address, read track, write track.
            commandType = 3
        }
        if commandType != 1 && value & CommandBits.typeIIorIIISettle != 0 { isCommandSettle = true }
        if command == Command.writeSector || command == Command.writeSectorMulti || command == Command.writeTrack {
            isCommandWrite = true
            isCommandDeleted = value & CommandBits.typeIIDeleted != 0
        }
        // All but force interrupt clear INTRQ, DRQ and the result bits, set
        // busy, and spin up if need be and not inhibited.
        setDrq(false)
        setIntRq(false)
        statusRegister = statusRegister & Status.motorOn | Status.busy

        indexPulseCount = 0
        if statusRegister & Status.motorOn != 0 {
            settleThenDispatch()
        } else {
            setMotor(true)
            // A strange facility: sensible for a seek, as the head can get
            // moving while the motor spins up, but other commands start at
            // once too.
            if value & CommandBits.disableSpinUp != 0 {
                indexPulseCount = 6
                settleThenDispatch()
            } else {
                setState(.spinUpWait)
            }
        }
    }

    private func stepRateMs(_ value: UInt8) -> Int {
        switch value & 0x03 {
        case 0: return 6
        case 1: return 12
        case 2: return variant == .wd1772 ? 2 : 20
        default: return variant == .wd1772 ? 3 : 30
        }
    }

    private var headSettleUs: Int {
        (variant == .wd1772 ? Self.wd1772HeadSettleMs : Self.wd1770HeadSettleMs) * 1000
    }

    private func handleForceInterrupt(_ value: UInt8) {
        let bits = value & 0x0F
        // From testing on a real 1772 (beebjit):
        // - The command is aborted at once in all cases.
        // - The completion INTRQ is inhibited for &D0 (Watford DDFS cares).
        // - If the motor is off, it spins up and goes idle, a little like a
        //   type I command: the index pulse shows in the status register.
        // - Interrupt on index pulse is only for the current command.
        if statusRegister & Status.busy != 0 {
            // Any pending timer belongs to the command being aborted.
            clearTimer()
            commandDone(raiseIntRq: false)
        } else {
            indexPulseCount = 0
            commandType = 1
            statusRegister &= Status.motorOn
            setMotor(true)
        }
        if bits & ForceInterruptBits.immediate != 0 { setIntRq(true) }
        isInterruptOnIndexPulse = bits & ForceInterruptBits.indexPulse != 0
        // The other two bits interrupt on the ready line's transitions. The
        // BBC ties READY active, so neither can happen.
    }

    private func timerFired() {
        guard statusRegister & Status.busy != 0 else { return }
        let fired = timerState
        timerState = .none
        switch fired {
        case .settle:
            dispatchCommand()
        case .seek:
            if command >= Command.stepNoUpdate && command <= Command.stepOutWithUpdate {
                checkVerify()
            } else {
                doSeekStepOrVerify()
            }
        case .done:
            doneTimer()
        case .verifySettle:
            indexPulseCount = 0
            setState(.searchID)
        case .none:
            break
        }
    }

    private func setControl(_ value: UInt8) {
        let drive: DiscDrive? = value & (Control.drive0 | Control.drive1) != 0
            ? drives[value & Control.drive0 != 0 ? 0 : 1] : nil
        if currentDrive !== drive { currentDrive?.notifySeekEnd() }
        currentDrive = drive
        currentDrive?.selectSide(upper: value & Control.side != 0)
        for each in drives { each.set32usMode(value & Control.singleDensity == 0) }
        control = value

        guard isReset else { return }
        clearState()
        setMotor(false)
        statusRegister = 0
        // On a real machine, reset seems to hold the sector register at 1
        // but leave track and data alone (and let them change).
        sectorRegister = 1
        intrq = false
        drq = false
        updateNMI()
        markDetector = 0
        dataShifter = 0
        dataShiftCount = 0
        isIndexPulse = false
        lastMFMBit = false
        deliverData = 0
        deliverIsMarker = false
    }

    /// MO is one line on the drive cable, so every drive turns while it's on.
    private func setMotor(_ on: Bool) {
        if on {
            statusRegister |= Status.motorOn
        } else {
            statusRegister &= ~Status.motorOn
        }
        for drive in drives {
            if on {
                drive.startSpinning(at: time)
            } else {
                drive.stopSpinning(at: time)
            }
        }
    }

    private func makeSeekNoise(_ delta: Int) {
        currentDrive?.notifySeekAmount(delta, stepMs: commandStepRateMs)
    }

    private func dispatchCommand() {
        if isCommandWrite && currentDrive?.writeProtected == true {
            statusRegister |= Status.writeProtected
            commandDone(raiseIntRq: true)
            return
        }

        switch command {
        case Command.restore:
            trackRegister = 0xFF
            dataRegister = 0
            // The head steps out from wherever it is, whatever the track register says.
            if let currentDrive { makeSeekNoise(-currentDrive.logicalTrack) }
            doSeekStepOrVerify()
        case Command.seek:
            makeSeekNoise(Int(dataRegister) - Int(trackRegister))
            doSeekStepOrVerify()
        case Command.stepNoUpdate, Command.stepWithUpdate:
            makeSeekNoise(lastStepDirection)
            doSeekStep(lastStepDirection, updateTrack: command == Command.stepWithUpdate)
        case Command.stepInNoUpdate, Command.stepInWithUpdate:
            makeSeekNoise(1)
            doSeekStep(1, updateTrack: command == Command.stepInWithUpdate)
        case Command.stepOutNoUpdate, Command.stepOutWithUpdate:
            makeSeekNoise(-1)
            doSeekStep(-1, updateTrack: command == Command.stepOutWithUpdate)
        case Command.readTrack:
            setState(.waitIndex)
            indexPulseCount = 0
        case Command.writeTrack:
            setState(.writeTrackSetup)
            indexPulseCount = 0
        default:
            // Read and write sector, read address.
            setState(.searchID)
            indexPulseCount = 0
        }
    }

    // MARK: Bit processor

    private func pulsesReceived(_ pulses: UInt32, count: Int) {
        let wasIndexPulse = isIndexPulse
        isIndexPulse = currentDrive?.indexPulse ?? false
        let isIndexEdge = isIndexPulse && !wasIndexPulse
        let isMFM = count == 16

        if isInterruptOnIndexPulse && isIndexEdge { setIntRq(true) }

        // Idle after a type I command, the index pulse and track 0 bits
        // stay maintained, until spin-down.
        updateTypeIStatusBits()

        switch phase {
        case .idle:
            pulsesIdle()
        case .timerWait:
            break
        case .spinUpWait:
            if indexPulseCount >= 6 {
                if commandType == 1 { statusRegister |= Status.typeISpinUpDone }
                settleThenDispatch()
            }
        case .waitIndex:
            if isIndexEdge {
                setState(.inReadTrack)
                // This byte, right after the index pulse, is part of the
                // track (confirmed with a real 1772 and Gotek).
                bitstreamReceived(pulses, count: count, isIndexEdge: false)
            }
        case .searchID, .inID, .searchData, .inData, .inReadTrack:
            bitstreamReceived(pulses, count: count, isIndexEdge: isIndexEdge)
            if indexPulseCount >= 6 {
                statusRegister |= Status.recordNotFound
                commandDone(raiseIntRq: true)
            }
        case .writeSectorDelay:
            pulsesSectorDelay(isMFM: isMFM)
        case .writeSectorLeadInFM:
            writeByte(isMFM: isMFM, 0x00, isMarker: false)
            stateCount += 1
            if stateCount == 6 { setState(.writeSectorMarkerFM) }
        case .writeSectorLeadInMFM:
            if stateCount >= 11 { writeByte(isMFM: isMFM, 0x00, isMarker: false) }
            stateCount += 1
            if stateCount == 23 { setState(.writeSectorMarkerMFM) }
        case .writeSectorMarkerFM:
            let mark = dataMark
            crc = IBMDiscFormat.crcAdd(IBMDiscFormat.crcInit(mfm: false), mark)
            writeByte(isMFM: false, mark, isMarker: true)
            setState(.writeSectorBody)
        case .writeSectorMarkerMFM:
            if stateCount < 3 { writeByte(isMFM: true, 0xA1, isMarker: true) }
            stateCount += 1
            if stateCount == 4 {
                let mark = dataMark
                crc = IBMDiscFormat.crcAdd(IBMDiscFormat.crcInit(mfm: true), mark)
                writeByte(isMFM: true, mark, isMarker: false)
                setState(.writeSectorBody)
            }
        case .writeSectorBody:
            pulsesWriteSectorBody(isMFM: isMFM)
        case .checkMulti:
            if isCommandMulti {
                sectorRegister &+= 1
                indexPulseCount = 0
                setState(.searchID)
            } else {
                commandDone(raiseIntRq: true)
            }
        case .writeTrackSetup:
            pulsesWriteTrackSetup()
        case .inWriteTrack:
            pulsesInWriteTrack(isMFM: isMFM, isIndexEdge: isIndexEdge)
        case .done:
            commandDone(raiseIntRq: true)
        }

        if isIndexEdge { indexPulseCount += 1 }
    }

    private var dataMark: UInt8 {
        isCommandDeleted ? IBMDiscFormat.deletedDataMarkDataPattern : IBMDiscFormat.dataMarkDataPattern
    }

    private func pulsesIdle() {
        // Sources disagree on 9 or 10 index pulses to spin down.
        guard indexPulseCount >= 9 else { return }
        setMotor(false)
        // In scarybeasts' testing on a 1772 the polled track 0 and index
        // bits clear on spin down; write protect is assumed to go too.
        if commandType == 1 { statusRegister &= ~Self.typeIPolledStatus }
    }

    private func settleThenDispatch() {
        if isCommandSettle {
            startTimer(.settle, us: headSettleUs)
        } else {
            dispatchCommand()
        }
    }

    private func pulsesSectorDelay(isMFM: Bool) {
        // Byte for byte as the datasheet.
        if stateCount == 0 {
            indexPulseCount = 0
        } else if stateCount == 1 {
            setDrq(true)
        } else if stateCount == 10 && statusRegister & Status.drq != 0 {
            statusRegister |= Status.lostByte
            commandDone(raiseIntRq: true)
        }
        stateCount += 1
        if stateCount == 12 { setState(isMFM ? .writeSectorLeadInMFM : .writeSectorLeadInFM) }
    }

    private func pulsesWriteSectorBody(isMFM: Bool) {
        if stateCount < onDiscLength {
            var byte = dataRegister
            if statusRegister & Status.drq != 0 {
                byte = 0
                statusRegister |= Status.lostByte
            }
            crc = IBMDiscFormat.crcAdd(crc, byte)
            writeByte(isMFM: isMFM, byte, isMarker: false)
            if stateCount != onDiscLength - 1 { setDrq(true) }
        } else if stateCount < onDiscLength + 2 {
            writeByte(isMFM: isMFM, UInt8(crc >> 8), isMarker: false)
            crc <<= 8
        } else {
            writeByte(isMFM: isMFM, 0xFF, isMarker: false)
            setState(.checkMulti)
        }
        stateCount += 1
    }

    private func pulsesWriteTrackSetup() {
        if stateCount == 0 {
            indexPulseCount = 0
            setDrq(true)
        } else if stateCount == 3 {
            if statusRegister & Status.drq != 0 {
                statusRegister |= Status.lostByte
                commandDone(raiseIntRq: true)
            } else {
                setState(.inWriteTrack)
                return
            }
        }
        stateCount += 1
    }

    private func pulsesInWriteTrack(isMFM: Bool, isIndexEdge: Bool) {
        if stateCount == 0 && !isIndexEdge { return }
        if stateCount > 0 && isIndexEdge {
            commandDone(raiseIntRq: true)
            return
        }
        if isWriteTrackCRCSecondByte {
            writeByte(isMFM: isMFM, UInt8(crc & 0xFF), isMarker: false)
            isWriteTrackCRCSecondByte = false
            setDrq(true)
            return
        }
        var byte = dataRegister
        if statusRegister & Status.drq != 0 {
            byte = 0
            statusRegister |= Status.lostByte
        }
        var isMarker = false
        var isPresetCRC = false
        switch byte {
        case 0xF5:
            // Documented as not allowed in FM, where it writes 0xA1 as in
            // MFM; whether clocks go missing or the CRC presets isn't known.
            // jsbeeb rejects it; here FM gets a plain 0xA1 with a preset CRC.
            isMarker = isMFM
            isPresetCRC = true
            byte = 0xA1
        case 0xF6:
            isMarker = isMFM
            byte = 0xC2
        case 0xF8, 0xF9, 0xFA, 0xFB, 0xFE:
            if !isMFM {
                isMarker = true
                isPresetCRC = true
            }
        case Self.fmIndexMark:
            if !isMFM { isMarker = true }
        default:
            break
        }
        if isPresetCRC { crc = IBMDiscFormat.crcInit(mfm: isMFM) }
        if byte == 0xF7 {
            writeByte(isMFM: isMFM, UInt8(crc >> 8), isMarker: false)
            isWriteTrackCRCSecondByte = true
        } else {
            writeByte(isMFM: isMFM, byte, isMarker: isMarker)
            if !(isMFM && isPresetCRC) { crc = IBMDiscFormat.crcAdd(crc, byte) }
            setDrq(true)
        }
        stateCount += 1
    }

    private func markDetectorTriggered() -> Bool {
        if isDoubleDensity {
            // Unsure exactly when MFM syncs are spotted. Here it's MFM 0x00
            // then a sync, 0xA1 or 0xC2. The documented sequences are 12x
            // 0x00 then 3x 0xA1 (sync) or 3x 0xC2 (index).
            let lastWord = markDetector & 0xFFFF_FFFF
            if lastWord == 0xAAAA_4489 {
                deliverData = 0xA1
                return true
            }
            // Ordinary data can encode this too (01 FE 29 does), so it only
            // resyncs where the spec says it may, in read track.
            if lastWord == 0xAAAA_5224 && phase == .inReadTrack {
                deliverData = 0xC2
                return true
            }
            // The byte after 3 syncs is a marker. After 3 index syncs it's
            // the index mark, which opens no field, so stays untagged.
            if markDetector & 0xFFFF_FFFF_FFFF_0000 == 0x4489_4489_4489_0000 { deliverIsMarker = true }
            return false
        }
        // The FM mark detector seems to need 4 data bits' worth of zeros,
        // with clock bits set, to trigger (scarybeasts' real 1772).
        guard markDetector & 0x0000_FFFF_0000_0000 == 0x0000_8888_0000_0000 else { return false }
        let fm = IBMDiscFormat.fmFrom2usPulses(UInt32(truncatingIfNeeded: markDetector))
        // A mark reads back with the clocks write track gives it.
        guard !fm.iffy, let markClocks = Self.fmMarkerClocks(fm.data), fm.clocks == markClocks else { return false }
        deliverData = fm.data
        deliverIsMarker = fm.data != Self.fmIndexMark
        return true
    }

    private func bitReceived(_ bit: Bool) {
        // The mark detector always runs: read track resyncs mid-command.
        markDetector = markDetector << 1 | (bit ? 1 : 0)
        if markDetectorTriggered() {
            dataShifter = 0
            dataShiftCount = 0
            return
        }
        dataShifter = dataShifter << 1 | (bit ? 1 : 0)
        dataShiftCount += 1
        if isDoubleDensity {
            if dataShiftCount == 16 {
                deliverData = IBMDiscFormat.mfmFrom2usPulses(dataShifter)
                dataShifter = 0
                dataShiftCount = 0
            }
        } else if dataShiftCount == 32 {
            let fm = IBMDiscFormat.fmFrom2usPulses(dataShifter)
            // MFM read as FM has pulses off the 4us grid: unstable bits.
            deliverData = fm.iffy
                ? IBMDiscFormat.fmFrom2usPulses(currentDrive?.quasiRandomPulses(time) ?? 0).data
                : fm.data
            dataShifter = 0
            dataShiftCount = 0
        }
    }

    private func bitstreamReceived(_ pulses: UInt32, count: Int, isIndexEdge: Bool) {
        var pulses = pulses << (32 - count)
        for _ in 0..<count {
            bitReceived(pulses & 0x8000_0000 != 0)
            pulses <<= 1
        }
        byteReceived(isIndexEdge: isIndexEdge)
    }

    private func writeByte(isMFM: Bool, _ byte: UInt8, isMarker: Bool) {
        let pulses: UInt32
        if isMFM {
            if isMarker {
                pulses = byte == 0xC2 ? IBMDiscFormat.mfmC2Sync : IBMDiscFormat.mfmA1Sync
            } else {
                let encoded = IBMDiscFormat.mfmTo2usPulses(lastBit: lastMFMBit, data: byte)
                lastMFMBit = encoded.lastBit
                pulses = encoded.pulses
            }
        } else {
            let clocks = isMarker ? Self.fmMarkerClocks(byte) ?? 0xFF : 0xFF
            pulses = IBMDiscFormat.fmTo2usPulses(clocks: clocks, data: byte)
        }
        currentDrive?.writePulses(pulses)
    }

    private static func fmMarkerClocks(_ byte: UInt8) -> UInt8? {
        switch byte {
        case fmIndexMark: return 0xD7
        case 0xF8, 0xF9, 0xFA, 0xFB, 0xFE: return IBMDiscFormat.markClockPattern
        default: return nil
        }
    }

    private func updateTypeIStatusBits() {
        guard commandType == 1 else { return }
        statusRegister &= ~Self.typeIPolledStatus
        guard let drive = currentDrive else { return }
        if drive.track == 0 { statusRegister |= Status.typeITrack0 }
        if drive.indexPulse { statusRegister |= Status.typeIIndex }
        if drive.writeProtected { statusRegister |= Status.writeProtected }
    }

    // MARK: Timer and completion

    private func setState(_ newPhase: Phase) {
        phase = newPhase
        stateCount = 0
    }

    private func clearTimer() {
        timerState = .none
        timerAt = .max
    }

    private func clearState() {
        setState(.idle)
        clearTimer()
        indexPulseCount = 0
    }

    private func startTimer(_ state: TimerState, us: Int) {
        timerState = state
        setState(.timerWait)
        timerAt = time + Int64(us)
    }

    private func commandDone(raiseIntRq: Bool) {
        doRaiseIntRq = raiseIntRq
        startTimer(.done, us: Self.doneDelayUs)
    }

    private func doneTimer() {
        statusRegister &= ~Status.busy
        clearState()
        updateTypeIStatusBits()
        // DRQ is left as it is.
        if doRaiseIntRq { setIntRq(true) }
    }

    /// A restore that steps 255 times without finding track 0 stops there,
    /// with a seek error if it was to verify.
    private func giveUpRestore() {
        currentDrive?.notifySeekEnd()
        if isCommandVerify { statusRegister |= Status.recordNotFound }
        commandDone(raiseIntRq: true)
    }

    private func checkVerify() {
        currentDrive?.notifySeekEnd()
        if isCommandVerify {
            startTimer(.verifySettle, us: headSettleUs)
        } else {
            commandDone(raiseIntRq: true)
        }
    }

    private func doSeekStep(_ direction: Int, updateTrack: Bool) {
        lastStepDirection = direction
        currentDrive?.seekOneTrack(direction)
        if updateTrack { trackRegister = UInt8(truncatingIfNeeded: Int(trackRegister) + direction) }
        // TRK0 may have changed.
        updateTypeIStatusBits()
        startTimer(.seek, us: commandStepRateMs * 1000)
    }

    private func doSeekStepOrVerify() {
        if trackRegister == dataRegister {
            if command == Command.restore && currentDrive?.track != 0 {
                giveUpRestore()
            } else {
                checkVerify()
            }
            return
        }
        let direction = trackRegister > dataRegister ? -1 : 1
        if currentDrive?.track == 0 && direction == -1 {
            trackRegister = 0
            checkVerify()
            return
        }
        doSeekStep(direction, updateTrack: true)
    }

    // MARK: Bytes read

    private static func isIDMark(_ byte: UInt8) -> Bool { byte >= 0xFC }
    private static func isDataMark(_ byte: UInt8) -> Bool { byte == 0xFA || byte == 0xFB }
    private static func isDeletedDataMark(_ byte: UInt8) -> Bool { byte == 0xF8 || byte == 0xF9 }

    private func byteReceived(isIndexEdge: Bool) {
        let isMarker = deliverIsMarker
        let byte = deliverData
        deliverIsMarker = false

        switch phase {
        case .searchID:
            // The WD1772 takes the whole range of marks (Jean Louis-Guerin's
            // WD1772 specification, "Type II commands").
            guard isMarker && Self.isIDMark(byte) else { break }
            setState(.inID)
            crc = IBMDiscFormat.crcAdd(IBMDiscFormat.crcInit(mfm: isDoubleDensity), byte)
        case .inID:
            byteReceivedInID(byte)
        case .searchData:
            byteReceivedSearchData(byte, isMarker: isMarker)
        case .inData:
            byteReceivedInData(byte)
        case .inReadTrack:
            if isIndexEdge {
                commandDone(raiseIntRq: true)
            } else {
                sendDataToHost(byte)
            }
        default:
            break
        }
    }

    private func byteReceivedInID(_ byte: UInt8) {
        let isReadAddress = command == Command.readAddress
        switch stateCount {
        case 0:
            onDiscTrack = byte
            // "The Track Address of the ID field is written into the sector register."
            if isReadAddress { sectorRegister = byte }
        case 2:
            onDiscSector = byte
        case 3:
            // Only the low two bits count (Jean Louis-Guerin's WD1772 specification).
            onDiscLength = 128 << Int(byte & 0x03)
        default:
            break
        }
        // Unlike the 8271, the CRC bytes come too.
        if isReadAddress { sendDataToHost(byte) }
        if stateCount < 4 {
            crc = IBMDiscFormat.crcAdd(crc, byte)
        } else {
            onDiscCRC = onDiscCRC << 8 | UInt16(byte)
        }
        stateCount += 1
        guard stateCount == 6 else { return }

        let isCRCError = crc != onDiscCRC
        if isReadAddress {
            if isCRCError { statusRegister |= Status.crcError }
            // A single record, not synchronised to the index. The 1770
            // delivers the last byte's DRQ separately from dropping busy.
            setState(.done)
            return
        }
        // No CRC error unless the fields match.
        if trackRegister != onDiscTrack || commandType == 2 && sectorRegister != onDiscSector {
            setState(.searchID)
            return
        }
        if isCRCError {
            // Unlike the 8271, the 1770 keeps going.
            statusRegister |= Status.crcError
            setState(.searchID)
            return
        }
        if commandType == 1 {
            commandDone(raiseIntRq: true)
        } else if isCommandWrite {
            setState(.writeSectorDelay)
        } else {
            setState(.searchData)
        }
    }

    private func byteReceivedSearchData(_ byte: UInt8, isMarker: Bool) {
        stateCount += 1
        let multiplier = isDoubleDensity ? 2 : 1
        // As the 8271, the data mark is only seen after 14 bytes; unlike it,
        // the 1770 gives up a while later.
        if stateCount < 14 * multiplier { return }
        if stateCount > 31 * multiplier {
            setState(.searchID)
            return
        }
        guard isMarker && (Self.isDataMark(byte) || Self.isDeletedDataMark(byte)) else { return }
        // On a real 1772 the deleted bit shows at once, and on a multi-sector
        // read stays set once any deleted sector is seen.
        if Self.isDeletedDataMark(byte) { statusRegister |= Status.deletedMark }
        setState(.inData)
        // A header CRC error can be followed by a good matching header.
        statusRegister &= ~Status.crcError
        crc = IBMDiscFormat.crcAdd(IBMDiscFormat.crcInit(mfm: isDoubleDensity), byte)
    }

    private func byteReceivedInData(_ byte: UInt8) {
        stateCount += 1
        if stateCount <= onDiscLength {
            crc = IBMDiscFormat.crcAdd(crc, byte)
            sendDataToHost(byte)
            return
        }
        if stateCount <= onDiscLength + 2 {
            onDiscCRC = onDiscCRC << 8 | UInt16(byte)
            return
        }
        if crc != onDiscCRC {
            // Terminal, even mid multi-sector read.
            statusRegister |= Status.crcError
            commandDone(raiseIntRq: true)
            return
        }
        setState(.checkMulti)
    }

    private func sendDataToHost(_ byte: UInt8) {
        setDrq(true)
        dataRegister = byte
    }

    // MARK: State

    /// Everything about the controller and its drives (and their discs; see
    /// `DiscDrive.restore`), mid-command or not.
    public struct State: Codable, Sendable, Equatable {
        fileprivate var variant: Variant
        fileprivate var drives: [DiscDrive.State]
        fileprivate var intrq: Bool
        fileprivate var drq: Bool
        fileprivate var time: Int64
        fileprivate var timerAt: Int64
        fileprivate var control: UInt8
        fileprivate var latch: UInt8?
        fileprivate var statusRegister: UInt8
        fileprivate var trackRegister: UInt8
        fileprivate var sectorRegister: UInt8
        fileprivate var dataRegister: UInt8
        fileprivate var doRaiseIntRq: Bool
        fileprivate var isIndexPulse: Bool
        fileprivate var isInterruptOnIndexPulse: Bool
        fileprivate var isWriteTrackCRCSecondByte: Bool
        fileprivate var command: UInt8
        fileprivate var commandType: Int
        fileprivate var isCommandSettle: Bool
        fileprivate var isCommandWrite: Bool
        fileprivate var isCommandVerify: Bool
        fileprivate var isCommandMulti: Bool
        fileprivate var isCommandDeleted: Bool
        fileprivate var commandStepRateMs: Int
        fileprivate var lastStepDirection: Int
        fileprivate var phase: Phase
        fileprivate var timerState: TimerState
        fileprivate var stateCount: Int
        fileprivate var indexPulseCount: Int
        fileprivate var markDetector: UInt64
        fileprivate var dataShifter: UInt32
        fileprivate var dataShiftCount: Int
        fileprivate var deliverData: UInt8
        fileprivate var deliverIsMarker: Bool
        fileprivate var crc: UInt16
        fileprivate var onDiscTrack: UInt8
        fileprivate var onDiscSector: UInt8
        fileprivate var onDiscLength: Int
        fileprivate var onDiscCRC: UInt16
        fileprivate var lastMFMBit: Bool
    }

    public var state: State {
        State(variant: variant, drives: drives.map(\.state), intrq: intrq, drq: drq, time: time, timerAt: timerAt,
              control: control, latch: latch, statusRegister: statusRegister, trackRegister: trackRegister,
              sectorRegister: sectorRegister, dataRegister: dataRegister, doRaiseIntRq: doRaiseIntRq,
              isIndexPulse: isIndexPulse, isInterruptOnIndexPulse: isInterruptOnIndexPulse,
              isWriteTrackCRCSecondByte: isWriteTrackCRCSecondByte, command: command, commandType: commandType,
              isCommandSettle: isCommandSettle, isCommandWrite: isCommandWrite, isCommandVerify: isCommandVerify,
              isCommandMulti: isCommandMulti, isCommandDeleted: isCommandDeleted,
              commandStepRateMs: commandStepRateMs, lastStepDirection: lastStepDirection, phase: phase,
              timerState: timerState, stateCount: stateCount, indexPulseCount: indexPulseCount,
              markDetector: markDetector, dataShifter: dataShifter, dataShiftCount: dataShiftCount,
              deliverData: deliverData, deliverIsMarker: deliverIsMarker, crc: crc, onDiscTrack: onDiscTrack,
              onDiscSector: onDiscSector, onDiscLength: onDiscLength, onDiscCRC: onDiscCRC, lastMFMBit: lastMFMBit)
    }

    /// Restores the controller and its drives. Leaves the drives' and
    /// discs' callbacks as they are. The state must be from the same variant.
    public func restore(_ state: State) {
        precondition(state.variant == variant && state.drives.count == drives.count, "Not this controller's state")
        for (drive, driveState) in zip(drives, state.drives) { drive.restore(driveState) }
        intrq = state.intrq
        drq = state.drq
        time = state.time
        timerAt = state.timerAt
        control = state.control
        latch = state.latch ?? 0
        // Only the latch picks the drive.
        currentDrive = control & (Control.drive0 | Control.drive1) != 0
            ? drives[control & Control.drive0 != 0 ? 0 : 1] : nil
        statusRegister = state.statusRegister
        trackRegister = state.trackRegister
        sectorRegister = state.sectorRegister
        dataRegister = state.dataRegister
        doRaiseIntRq = state.doRaiseIntRq
        isIndexPulse = state.isIndexPulse
        isInterruptOnIndexPulse = state.isInterruptOnIndexPulse
        isWriteTrackCRCSecondByte = state.isWriteTrackCRCSecondByte
        command = state.command
        commandType = state.commandType
        isCommandSettle = state.isCommandSettle
        isCommandWrite = state.isCommandWrite
        isCommandVerify = state.isCommandVerify
        isCommandMulti = state.isCommandMulti
        isCommandDeleted = state.isCommandDeleted
        commandStepRateMs = state.commandStepRateMs
        lastStepDirection = state.lastStepDirection
        phase = state.phase
        timerState = state.timerState
        stateCount = state.stateCount
        indexPulseCount = state.indexPulseCount
        markDetector = state.markDetector
        dataShifter = state.dataShifter
        dataShiftCount = state.dataShiftCount
        deliverData = state.deliverData
        deliverIsMarker = state.deliverIsMarker
        crc = state.crc
        onDiscTrack = state.onDiscTrack
        onDiscSector = state.onDiscSector
        onDiscLength = state.onDiscLength
        onDiscCRC = state.onDiscCRC
        lastMFMBit = state.lastMFMBit
        updateNMI()
        updateNextEvent()
    }
}
