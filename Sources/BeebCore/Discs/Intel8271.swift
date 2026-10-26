// Intel 8271 floppy disc controller, with the Model B's drive ready logic.
//
// A port of jsbeeb's intel-fdc.js (Matt Godbolt et al., GPLv3), itself
// translated from beebjit by Chris Evans, whose model follows the 8271's own
// microcode (https://scarybeastsecurity.blogspot.com/2020/11/reverse-engineering-forgotten-1970s.html).
//
// jsbeeb runs this from a scheduler of timed callbacks. Here `tick()` runs
// once per microsecond and fires whatever has come due: each drive's
// rotation step (one FM byte, 64us at full speed, see DiscDrive), the
// step/settle/head-load timer, and the end of an NMI drop after an abort.
// With nothing due, a tick is an increment and a compare.

public final class Intel8271 {
    /// Internal register numbers (the microcontroller's RAM, which many
    /// uses share) and the MMIO ports beyond it.
    private enum R {
        static let internalPointer = 0x00
        static let internalCountMsbCopy = 0x00
        static let internalParamCount = 0x01
        static let internalSeekRetryCount = 0x01
        static let internalParamDataMarker = 0x02
        static let internalParam5 = 0x03
        static let internalParam4 = 0x04
        static let internalParam3 = 0x05
        static let internalParam2 = 0x06
        static let internalParam1 = 0x07
        static let internalHeaderPointer = 0x08
        static let internalMsCountHi = 0x08
        static let internalMsCountLo = 0x09
        static let internalSeekCount = 0x0A
        static let internalIdSector = 0x0A
        static let internalSeekTarget1 = 0x0B
        static let internalDynamicDispatch = 0x0B
        static let internalSeekTarget2 = 0x0C
        static let internalIdTrack = 0x0C
        static let headStepRate = 0x0D
        static let headSettleTime = 0x0E
        static let headLoadUnload = 0x0F
        static let badTrack1Drive0 = 0x10
        static let trackDrive0 = 0x12
        static let internalCountLsb = 0x13
        static let internalCountMsb = 0x14
        static let internalDriveInCopy = 0x15
        static let internalWriteRunData = 0x15
        static let internalGap2Skip = 0x15
        static let internalResult = 0x16
        static let mode = 0x17
        static let internalStatus = 0x17
        static let badTrack1Drive1 = 0x18
        static let trackDrive1 = 0x1A
        static let internalDriveInLatched = 0x1B
        static let internalIndexPulseCount = 0x1C
        static let internalData = 0x1D
        static let internalParameter = 0x1E
        static let internalCommand = 0x1F

        static let mmioDriveIn = 0x22
        static let mmioDriveOut = 0x23
        static let mmioClocks = 0x24
        static let mmioData = 0x25
    }

    public enum DriveOut {
        public static let select1: UInt8 = 0x80
        public static let select0: UInt8 = 0x40
        public static let side: UInt8 = 0x20
        public static let lowHeadCurrent: UInt8 = 0x10
        public static let loadHead: UInt8 = 0x08
        public static let direction: UInt8 = 0x04
        public static let step: UInt8 = 0x02
        public static let writeEnable: UInt8 = 0x01
        public static let selectFlags: UInt8 = 0xC0
    }

    private enum Mode {
        static let singleActuator: UInt8 = 0x02
        static let noDMA: UInt8 = 0x01
    }

    public enum Result {
        public static let ok: UInt8 = 0x00
        public static let clockError: UInt8 = 0x08
        public static let lateDMA: UInt8 = 0x0A
        public static let idCRCError: UInt8 = 0x0C
        public static let dataCRCError: UInt8 = 0x0E
        public static let driveNotReady: UInt8 = 0x10
        public static let writeProtected: UInt8 = 0x12
        public static let trackZeroNotFound: UInt8 = 0x14
        public static let sectorNotFound: UInt8 = 0x18
        public static let flagDeletedData: UInt8 = 0x20
    }

    private enum Command {
        static let scanData = 0
        static let scanDataAndDeleted = 1
        static let writeData = 2
        static let writeDeletedData = 3
        static let readData = 4
        static let readDataAndDeleted = 5
        static let readID = 6
        static let verify = 7
        static let format = 8
        static let seek = 10
        static let readDriveStatus = 11
        static let specify = 13
        static let writeSpecialRegister = 14
        static let readSpecialRegister = 15
    }

    public enum Status {
        public static let busy: UInt8 = 0x80
        public static let commandFull: UInt8 = 0x40
        public static let paramFull: UInt8 = 0x20
        public static let resultReady: UInt8 = 0x10
        public static let nmi: UInt8 = 0x08
        public static let needData: UInt8 = 0x04
    }

    fileprivate enum ParamAccept: UInt8, Codable { case none, command, specify }

    fileprivate enum IndexPulse: UInt8, Codable { case none, timeout, spindown, startReadID, startFormat, stopFormat }

    fileprivate enum TimerState: UInt8, Codable { case none, seekStep, postSeek }

    fileprivate enum Phase: UInt8, Codable {
        case null, idle
        case syncingForIDWait, syncingForID, checkIDMarker, inID, inIDCRC
        case syncingForData, checkDataMarker, inData, inDataCRC, skipGap2
        case writeRun, writeDataMark, writeSectorData, writeCRC2, writeCRC3, dynamicDispatch
        case formatWriteIDMarker, formatIDCRC2, formatIDCRC3, formatWriteDataMarker
        case formatDataCRC2, formatDataCRC3, formatGap4
    }

    fileprivate enum Call: UInt8, Codable {
        case uninitialised, unchanged, seek, readID, read, write, format
        case formatGap1OrGap3FFs, formatGap1OrGap300s, formatGap2FFs, formatGap200s, formatData
    }

    /// The Model B doesn't wire the drives' Ready lines to the 8271. ICs
    /// 83-86 make a selected drive ready on the second index pulse after
    /// selection and drop it once 8192 counts of a 31.25kHz clock (262ms)
    /// pass without one.
    static let readyTimeoutUs: Int64 = 8192 * 1_000_000 / 31250
    static let readyIndexPulses = 2

    public let drives: [DiscDrive]
    /// The INT output, which drives the 6502's NMI on the BBC.
    public private(set) var nmi = false

    /// Microseconds since power on.
    public private(set) var time: Int64 = 0
    private var nextEvent = Int64.max
    private var timerAt = Int64.max
    /// After an abort, NMI stays low until here, so that a completion
    /// raised in the same breath is a fresh edge.
    private var nmiLowUntil = Int64.max

    private var currentDrive: DiscDrive?
    private var ready = false
    private var readyPulses = 0
    private var lastIndexTime = Int64.min / 2

    private var paramCallback = ParamAccept.none
    private var indexPulseCallback = IndexPulse.none
    private var timerState = TimerState.none
    private var callContext = Call.uninitialised
    private var didSeekStep = false

    private var regs = InlineArray<32, UInt8>(repeating: 0)
    private var isResultReady = false
    private var status: UInt8 = 0
    private var mmioData: UInt8 = 0
    private var mmioClocks: UInt8 = 0
    private var driveOut: UInt8 = 0

    private var shiftRegister: UInt32 = 0
    private var numShifts = 0
    private var phase = Phase.null
    private var stateCount = 0
    private var stateIsIndexPulse = false
    private var crc: UInt16 = 0
    private var onDiscCRC: UInt16 = 0

    public init(drives: [DiscDrive] = [DiscDrive(id: 0), DiscDrive(id: 1)]) {
        precondition(drives.count == 2)
        self.drives = drives
        powerOnReset()
    }

    // MARK: State

    /// Everything about the controller and its drives (and their discs; see
    /// `DiscDrive.restore`), mid-command or not.
    public struct State: Codable, Sendable, Equatable {
        fileprivate var drives: [DiscDrive.State]
        fileprivate var nmi: Bool
        fileprivate var time: Int64
        fileprivate var timerAt: Int64
        fileprivate var nmiLowUntil: Int64
        fileprivate var currentDrive: Int?
        fileprivate var ready: Bool
        fileprivate var readyPulses: Int
        fileprivate var lastIndexTime: Int64
        fileprivate var paramCallback: ParamAccept
        fileprivate var indexPulseCallback: IndexPulse
        fileprivate var timerState: TimerState
        fileprivate var callContext: Call
        fileprivate var didSeekStep: Bool
        fileprivate var regs: [UInt8]
        fileprivate var isResultReady: Bool
        fileprivate var status: UInt8
        fileprivate var mmioData: UInt8
        fileprivate var mmioClocks: UInt8
        fileprivate var driveOut: UInt8
        fileprivate var shiftRegister: UInt32
        fileprivate var numShifts: Int
        fileprivate var phase: Phase
        fileprivate var stateCount: Int
        fileprivate var stateIsIndexPulse: Bool
        fileprivate var crc: UInt16
        fileprivate var onDiscCRC: UInt16
    }

    public var state: State {
        State(drives: drives.map(\.state), nmi: nmi, time: time, timerAt: timerAt, nmiLowUntil: nmiLowUntil,
              currentDrive: currentDrive.flatMap { drive in drives.firstIndex { $0 === drive } },
              ready: ready, readyPulses: readyPulses, lastIndexTime: lastIndexTime,
              paramCallback: paramCallback, indexPulseCallback: indexPulseCallback, timerState: timerState,
              callContext: callContext, didSeekStep: didSeekStep, regs: (0..<32).map { regs[$0] },
              isResultReady: isResultReady, status: status, mmioData: mmioData, mmioClocks: mmioClocks,
              driveOut: driveOut, shiftRegister: shiftRegister, numShifts: numShifts, phase: phase,
              stateCount: stateCount, stateIsIndexPulse: stateIsIndexPulse, crc: crc, onDiscCRC: onDiscCRC)
    }

    /// Restores the controller and its drives. Leaves the drives' and
    /// discs' callbacks as they are.
    public func restore(_ state: State) {
        precondition(state.drives.count == drives.count && state.regs.count == 32, "Not an 8271's state")
        for (drive, driveState) in zip(drives, state.drives) { drive.restore(driveState) }
        nmi = state.nmi
        time = state.time
        timerAt = state.timerAt
        nmiLowUntil = state.nmiLowUntil
        currentDrive = state.currentDrive.flatMap { drives.indices.contains($0) ? drives[$0] : nil }
        ready = state.ready
        readyPulses = state.readyPulses
        lastIndexTime = state.lastIndexTime
        paramCallback = state.paramCallback
        indexPulseCallback = state.indexPulseCallback
        timerState = state.timerState
        callContext = state.callContext
        didSeekStep = state.didSeekStep
        for i in 0..<32 { regs[i] = state.regs[i] }
        isResultReady = state.isResultReady
        status = state.status
        mmioData = state.mmioData
        mmioClocks = state.mmioClocks
        driveOut = state.driveOut
        shiftRegister = state.shiftRegister
        numShifts = state.numShifts
        phase = state.phase
        stateCount = state.stateCount
        stateIsIndexPulse = state.stateIsIndexPulse
        crc = state.crc
        onDiscCRC = state.onDiscCRC
        updateNextEvent()
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
            if nmiLowUntil <= time {
                nmiLowUntil = .max
                updateNMI()
            } else if timerAt <= time {
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
        nextEvent = min(nmiLowUntil, timerAt, drives[0].timer, drives[1].timer)
    }

    private func rotate(_ drive: DiscDrive) {
        // The 8271 is FM only, so always gets 32 pulses.
        if let read = drive.rotationPulses(at: time), drive === currentDrive, read.count == 32 {
            pulsesReceived(read.pulses)
        }
        drive.advanceRotation(at: time)
    }

    // MARK: Reset

    public func powerOnReset() {
        // The reset line does most things.
        reset()
        regs = InlineArray(repeating: 0)
        isResultReady = false
        mmioData = 0
        mmioClocks = 0
        stateCount = 0
        stateIsIndexPulse = false
        updateNextEvent()
    }

    public func reset() {
        commandAbort()
        clearCallbacks()
        // Deselect any drive; ensures spin-down.
        setDriveOut(0)
        // On a real machine, status appears to be cleared but result and data not.
        statusLower(regs[R.internalStatus])
    }

    private func commandAbort() {
        // An abort mid-write doesn't leave a clean byte end on the disc.
        if driveOut & DriveOut.writeEnable != 0 {
            currentDrive?.writePulses(IBMDiscFormat.fmTo2usPulses(clocks: 0xFF, data: 0xFF))
        }
        // Lower NMI, so the completion NMI isn't lost (late DMA aborts with
        // NMI raised).
        nmi = false
        nmiLowUntil = time + 1
    }

    // MARK: Registers

    /// Reads &FE80 + `register`.
    public func read(_ register: Int) -> UInt8 {
        let value = peek(register)
        switch register & 7 {
        case 1:
            resultConsumed()
            statusLower(Status.nmi)
        case 4...7:
            statusLower(Status.needData | Status.nmi)
        default:
            break
        }
        return value
    }

    /// What `read` would return, without side effects.
    public func peek(_ register: Int) -> UInt8 {
        switch register & 7 {
        case 0: return status
        case 1: return regs[R.internalResult]
        // Not documented, but on a Model B these give the sector byte
        // counter's MSB and LSB.
        case 2: return regs[R.internalCountMsb]
        case 3: return regs[R.internalCountLsb]
        default: return regs[R.internalData]
        }
    }

    /// Writes &FE80 + `register`.
    public func write(_ register: Int, _ value: UInt8) {
        switch register & 7 {
        case 0:
            commandWritten(value)
        case 1:
            paramWritten(value)
        case 2:
            // Values other than 0 and 1 do odd things on a real 8271.
            if value == 1 { reset() }
        case 3:
            break
        default:
            statusLower(Status.needData | Status.nmi)
            regs[R.internalData] = value
        }
        updateNextEvent()
    }

    /// Each drive's activity light: its select line, gated by the motor.
    public func driveLight(_ drive: Int) -> Bool {
        drives[drive].spinning && drives[drive] === currentDrive
    }

    // MARK: Index pulses and ready

    private var index: Bool { currentDrive?.indexPulse ?? false }

    private func checkIndexPulse() {
        let wasIndexPulse = stateIsIndexPulse
        stateIsIndexPulse = index
        // Looking for the pulse going high.
        guard stateIsIndexPulse && !wasIndexPulse else { return }

        noteIndexPulse()
        switch indexPulseCallback {
        case .none:
            break
        case .timeout:
            // Too many index pulses without the sector times out. (So a huge
            // sector read hits the default 3 pulse limit.)
            regs[R.internalIndexPulseCount] &-= 1
            if regs[R.internalIndexPulseCount] == 0 { finishCommand(Result.sectorNotFound) }
        case .spindown:
            regs[R.internalIndexPulseCount] &-= 1
            if regs[R.internalIndexPulseCount] == 0 {
                spinDown()
                indexPulseCallback = .none
            }
        case .startFormat:
            // Format sets no index pulse timeout; it exits on the next index
            // pulse after all the sectors are written. GAP5 (param 4) isn't
            // supported: jsbeeb rejects it, here it's ignored.
            // Decrement GAP3 as the CRC generator emits a third byte as 0xFF.
            regs[R.internalParam2] &-= 1
            regs[R.internalDynamicDispatch] = 4
            // Writing starts at once, as index pulses are checked before the
            // read/write state.
            indexPulseCallback = .none
            // Param 5 is GAP1.
            writeFFsAnd00s(.formatGap1OrGap3FFs, Int(regs[R.internalParam5]))
        case .stopFormat:
            checkCompletion()
        case .startReadID:
            startIndexPulseTimeout()
            startSyncingForHeader()
        }
    }

    private func noteIndexPulse() {
        if indexPulsesStopped {
            ready = false
            readyPulses = 0
        }
        lastIndexTime = time
        readyPulses += 1
        if readyPulses >= Self.readyIndexPulses { ready = true }
    }

    private var indexPulsesStopped: Bool { time - lastIndexTime >= Self.readyTimeoutUs }

    /// The Beeb's ready latch, which the timeout clears without waiting for a pulse.
    private var driveReady: Bool { ready && !indexPulsesStopped }

    // MARK: Bit processor

    /// 32 pulses (one FM byte's worth) from the selected drive.
    private func pulsesReceived(_ pulses: UInt32) {
        checkIndexPulse()

        // All writing happens here. If the write gate is open outside a
        // command, it still writes, often making weak bits.
        if driveOut & DriveOut.writeEnable != 0 {
            currentDrive?.writePulses(IBMDiscFormat.fmTo2usPulses(clocks: mmioClocks, data: mmioData))
        }

        // The external data register is always copied to the bit processor's
        // data register; write states needing their own byte (gap, marker)
        // overwrite it below.
        mmioData = regs[R.internalData]

        switch phase {
        case .null, .idle:
            break
        case .syncingForIDWait, .syncingForID, .checkIDMarker, .inID, .inIDCRC,
             .skipGap2, .syncingForData, .checkDataMarker, .inData, .inDataCRC:
            var pulses = pulses
            for _ in 0..<16 {
                shiftDataBit(pulses & 0xC000_0000 != 0)
                pulses <<= 2
            }
        default:
            byteCallbackWriting()
        }
    }

    private func shiftDataBit(_ bit: Bool) {
        switch phase {
        case .syncingForIDWait:
            stateCount += 1
            // The controller needs 4 bytes to recover after a header before
            // the 2 byte sync (measured with READ ID).
            if stateCount == 4 * 8 * 2 { startSyncingForHeader() }
        case .syncingForID, .syncingForData:
            // Sync is 1010...: clock bits 1, data bits 0.
            if bit == (stateCount & 1 == 0) {
                stateCount += 1
            } else if stateCount >= 32 && stateCount & 1 != 0 {
                // A 1 data bit while in sync starts a marker byte.
                setState(phase == .syncingForID ? .checkIDMarker : .checkDataMarker)
                shiftRegister = 3
                numShifts = 2
            } else {
                stateCount = bit ? 1 : 0
            }
        case .checkIDMarker, .inID, .inIDCRC, .checkDataMarker, .inData, .inDataCRC, .skipGap2:
            shiftRegister = shiftRegister << 1 | (bit ? 1 : 0)
            numShifts += 1
            guard numShifts == 16 else { break }
            let clockByte = Self.extractBits(shiftRegister)
            let dataByte = Self.extractBits(shiftRegister << 1)
            // The 8271 doesn't deliver bytes with missing clock bits in the
            // middle of a synced stream.
            if clockByte == 0xFF || phase == .checkIDMarker || phase == .checkDataMarker || phase == .skipGap2 {
                byteCallbackReading(dataByte, clockByte)
            }
            shiftRegister = 0
            numShifts = 0
        default:
            break
        }
    }

    private static func extractBits(_ bits: UInt32) -> UInt8 {
        var byte: UInt8 = 0
        for i in 0..<8 where bits & (0x8000 >> (2 * i)) != 0 {
            byte |= 0x80 >> i
        }
        return byte
    }

    private var internalCommand: Int {
        Int(regs[R.internalCommand] & ~(DriveOut.selectFlags | 0x03)) >> 2
    }

    private func checkDataLossOK() -> Bool {
        // A BBC can't do DMA, which scans need, and the last byte must have
        // been taken.
        let command = internalCommand
        if regs[R.mode] & Mode.noDMA != 0
            && command != Command.scanData && command != Command.scanDataAndDeleted
            && regs[R.internalStatus] & Status.needData == 0 {
            return true
        }
        commandAbort()
        finishCommand(Result.lateDMA)
        return false
    }

    private func byteCallbackReading(_ dataByte: UInt8, _ clockByte: UInt8) {
        let command = internalCommand
        if irqCallbacks {
            guard checkDataLossOK() else { return }
            regs[R.internalData] = dataByte
            statusRaise(Status.nmi | Status.needData)
        }

        switch phase {
        case .skipGap2:
            // The ROM skips 11 bytes; with sync start-up the practical
            // minimum gap is 12 plus 2 of sync. The 8271 formats to 17.
            regs[R.internalGap2Skip] &-= 1
            guard regs[R.internalGap2Skip] == 0 else { break }
            if callContext == .read {
                setState(.syncingForData)
            } else if callContext == .write {
                doWriteRun(.write, 0x00)
            }
        case .checkIDMarker:
            if clockByte == IBMDiscFormat.markClockPattern && dataByte == IBMDiscFormat.idMarkDataPattern {
                crc = IBMDiscFormat.crcAdd(IBMDiscFormat.crcInit(mfm: false), dataByte)
                if command == Command.readID { startIRQCallbacks() }
                setState(.inID)
            } else {
                startSyncingForHeader()
            }
        case .inID:
            crc = IBMDiscFormat.crcAdd(crc, dataByte)
            writeRegister(regs[R.internalHeaderPointer], dataByte)
            regs[R.internalHeaderPointer] &-= 1
            if regs[R.internalHeaderPointer] & 0x07 == 0 {
                onDiscCRC = 0
                stopIRQCallbacks()
                setState(.inIDCRC)
            }
        case .inIDCRC:
            onDiscCRC = onDiscCRC << 8 | UInt16(dataByte)
            stateCount += 1
            guard stateCount == 2 else { break }
            // An ID CRC error ends things even if a later ID would match.
            guard checkCRC(Result.idCRCError) else { break }
            if regs[R.internalCommand] == 0x18 {
                // READ ID.
                checkCompletion()
            } else if regs[R.internalIdTrack] != regs[R.internalParam1] {
                // On a track mismatch, try twice more, stepping on.
                regs[R.internalSeekRetryCount] &+= 1
                if regs[R.internalSeekRetryCount] == 3 {
                    finishCommand(Result.sectorNotFound)
                } else {
                    doSeek(.unchanged)
                }
            } else if regs[R.internalIdSector] == regs[R.internalParam2] {
                regs[R.internalGap2Skip] = 11
                if callContext == .write {
                    // Set up for the first 5 bytes of the 0x00 sync.
                    regs[R.internalCountMsb] = 0
                    regs[R.internalCountLsb] = 5
                }
                setState(.skipGap2)
            } else {
                setState(.syncingForIDWait)
            }
        case .checkDataMarker:
            if clockByte == IBMDiscFormat.markClockPattern
                && (dataByte == IBMDiscFormat.dataMarkDataPattern
                    || dataByte == IBMDiscFormat.deletedDataMarkDataPattern) {
                var doIRQs = true
                if dataByte == IBMDiscFormat.deletedDataMarkDataPattern {
                    if regs[R.internalCommand] & 0x0F == 0 { doIRQs = false }
                    setResult(Result.flagDeletedData)
                }
                // No data for VERIFY.
                if regs[R.internalCommand] == 0x1C { doIRQs = false }
                if doIRQs { startIRQCallbacks() }
                crc = IBMDiscFormat.crcAdd(IBMDiscFormat.crcInit(mfm: false), dataByte)
                setState(.inData)
            } else {
                finishCommand(Result.clockError)
            }
        case .inData:
            crc = IBMDiscFormat.crcAdd(crc, dataByte)
            if decrementCounter() {
                onDiscCRC = 0
                setState(.inDataCRC)
            }
        case .inDataCRC:
            onDiscCRC = onDiscCRC << 8 | UInt16(dataByte)
            stateCount += 1
            guard stateCount == 2 else { break }
            guard checkCRC(Result.dataCRCError) else { break }
            checkCompletion()
        default:
            break
        }
    }

    private func callbackWriteRun() {
        guard decrementCounter() else {
            mmioData = regs[R.internalWriteRunData]
            crc = IBMDiscFormat.crcAdd(crc, mmioData)
            return
        }
        switch callContext {
        case .write:
            mmioData = 0
            startIRQCallbacks()
            setState(.writeDataMark)
        case .formatGap1OrGap3FFs:
            // Flip from writing FFs to 00s.
            regs[R.internalCountLsb] = 5
            doWriteRun(.formatGap1OrGap300s, 0x00)
        case .formatGap1OrGap300s:
            mmioData = 0
            startIRQCallbacks()
            setState(.formatWriteIDMarker)
        case .formatGap2FFs:
            regs[R.internalCountLsb] = 5
            doWriteRun(.formatGap200s, 0x00)
        case .formatGap200s:
            mmioData = 0
            setState(.formatWriteDataMarker)
        case .formatData:
            mmioData = UInt8(crc >> 8)
            setState(.formatDataCRC2)
        default:
            break
        }
    }

    private func callbackDynamicDispatch() {
        let routine = regs[R.internalDynamicDispatch]
        regs[R.internalDynamicDispatch] &+= 1
        switch routine {
        // 0-2: write sector.
        case 0:
            crc = IBMDiscFormat.crcAdd(crc, mmioData)
        case 1:
            mmioData = UInt8(crc >> 8)
            setState(.writeCRC2)
        case 2:
            checkCompletion()
        // 4-11: format. 4-7 write the 4 user-supplied header bytes.
        case 4...7:
            if routine == 4 { mmioClocks = 0xFF }
            if routine == 6 { stopIRQCallbacks() }
            crc = IBMDiscFormat.crcAdd(crc, mmioData)
        case 8:
            // Header CRC.
            mmioData = UInt8(crc >> 8)
            setState(.formatIDCRC2)
        case 9:
            // GAP2: 10 is its 0xFF length less one, as the CRC generator
            // emits a third 0xFF. (The ROM writes the LSB here, not the MSB.)
            regs[R.internalCountLsb] = 10
            writeFFsAnd00s(.formatGap2FFs, nil)
        case 10:
            resetSectorByteCount()
            doWriteRun(.formatData, 0xE5)
        case 11:
            // After the sector data CRC.
            mmioData = 0xFF
            regs[R.internalParam3] &-= 1
            if regs[R.internalParam3] & 0x1F == 0 {
                // All sectors done: GAP4 to the index. Param 3 = 1 makes
                // checkCompletion exit at once.
                regs[R.internalParam3] = 1
                indexPulseCallback = .stopFormat
                setState(.formatGap4)
            } else {
                // Next sector; param 2 is GAP3.
                regs[R.internalDynamicDispatch] = 4
                writeFFsAnd00s(.formatGap1OrGap3FFs, Int(regs[R.internalParam2]))
            }
        default:
            break
        }
    }

    private func byteCallbackWriting() {
        if irqCallbacks {
            guard checkDataLossOK() else { return }
            statusRaise(Status.nmi | Status.needData)
        }

        switch phase {
        case .writeRun:
            callbackWriteRun()
        case .writeDataMark:
            mmioData = regs[R.internalParamDataMarker]
            crc = IBMDiscFormat.crcAdd(IBMDiscFormat.crcInit(mfm: false), mmioData)
            mmioClocks = IBMDiscFormat.markClockPattern
            resetSectorByteCount()
            // This strange decrement is how the ROM does it.
            regs[R.internalCountLsb] &-= 1
            setState(.writeSectorData)
        case .writeSectorData:
            mmioClocks = 0xFF
            crc = IBMDiscFormat.crcAdd(crc, mmioData)
            if decrementCounter() {
                regs[R.internalDynamicDispatch] = 0
                setState(.dynamicDispatch)
            }
        case .writeCRC2, .formatIDCRC2, .formatDataCRC2:
            mmioData = UInt8(crc & 0xFF)
            setState(phase == .writeCRC2 ? .writeCRC3 : phase == .formatIDCRC2 ? .formatIDCRC3 : .formatDataCRC3)
        case .writeCRC3, .formatIDCRC3, .formatDataCRC3:
            mmioData = 0xFF
            setState(.dynamicDispatch)
        case .dynamicDispatch:
            callbackDynamicDispatch()
        case .formatWriteIDMarker, .formatWriteDataMarker:
            mmioData = phase == .formatWriteIDMarker ? IBMDiscFormat.idMarkDataPattern : IBMDiscFormat.dataMarkDataPattern
            mmioClocks = IBMDiscFormat.markClockPattern
            crc = IBMDiscFormat.crcAdd(IBMDiscFormat.crcInit(mfm: false), mmioData)
            setState(.dynamicDispatch)
        case .formatGap4:
            // To the index pulse, handled there.
            mmioData = 0xFF
        default:
            break
        }
    }

    private func resetSectorByteCount() {
        regs[R.internalCountMsb] = regs[R.internalCountMsbCopy]
        regs[R.internalCountLsb] = 0x80
    }

    private func checkCompletion() {
        guard checkDriveReady() else { return }
        driveOutLower(DriveOut.writeEnable)
        clearCallbacks()

        // One less sector to go. 0 sectors reads 32, as the 5-bit counter
        // underflows (with other side effects outside READ ID).
        regs[R.internalParam3] &-= 1
        if regs[R.internalParam3] & 0x1F == 0 {
            finishCommand(Result.ok)
        } else {
            // Just an increment for sector operations (R4 == 1), but it's
            // what the ROM does; and it re-dispatches the current command.
            regs[R.internalParam2] &+= regs[R.internalParam4] & 0x3F
            doCommandDispatch()
        }
    }

    private func checkCRC(_ error: UInt8) -> Bool {
        if crc == onDiscCRC { return true }
        finishCommand(error)
        return false
    }

    // MARK: Status

    private func statusRaise(_ flags: UInt8) {
        regs[R.internalStatus] |= flags
        if flags & Status.nmi != 0 { updateNMI() }
        updateExternalStatus()
    }

    private func statusLower(_ flags: UInt8) {
        regs[R.internalStatus] &= ~flags
        if flags & Status.nmi != 0 { updateNMI() }
        updateExternalStatus()
    }

    private func setResult(_ result: UInt8) {
        regs[R.internalResult] = result
        isResultReady = true
        updateExternalStatus()
    }

    private func updateNMI() {
        guard nmiLowUntil == .max else { return }
        nmi = regs[R.internalStatus] & Status.nmi != 0
    }

    private func updateExternalStatus() {
        // The real 8271 is a microcontroller taking tens of microseconds to
        // accept commands and parameters; here it's instant, so command and
        // parameter full are never seen (software only polls for them to
        // clear). Result ready is kept by the external register logic.
        status = regs[R.internalStatus] & (Status.busy | Status.nmi | Status.needData)
        if isResultReady { status |= Status.resultReady }
    }

    private func commandWritten(_ command: UInt8) {
        regs[R.internalCommand] = command
        statusRaise(Status.busy)
        statusLower(Status.commandFull)
        setResult(0)

        // Defaults, for the 1x128 byte sector commands.
        regs[R.internalParam3] = 1
        regs[R.internalParam4] = 1

        // From the logic in the 8271 ROM.
        let numParams: UInt8 = command & 0x18 != 0 ? command & 0x03 : 5
        regs[R.internalParamCount] = numParams
        if numParams != 0 {
            // Parameters write from R7 downwards.
            regs[R.internalPointer] = UInt8(R.internalParam1)
            paramCallback = .command
        } else {
            startCommand()
        }
    }

    private func resultConsumed() {
        isResultReady = false
        updateExternalStatus()
    }

    private func paramWritten(_ param: UInt8) {
        regs[R.internalParameter] = param
        resultConsumed()
        switch paramCallback {
        case .none:
            break
        case .command:
            writeRegister(regs[R.internalPointer], param)
            regs[R.internalPointer] &-= 1
            regs[R.internalParamCount] &-= 1
            if regs[R.internalParamCount] == 0 { startCommand() }
        case .specify:
            writeRegister(regs[R.internalPointer], param)
            regs[R.internalPointer] &+= 1
            regs[R.internalParamCount] &-= 1
            if regs[R.internalParamCount] == 0 { finishSimpleCommand() }
        }
    }

    private func readRegister(_ register: UInt8) -> UInt8 {
        let register = Int(register & 0x3F)
        if register < 32 { return regs[register] }
        switch register & 7 {
        case R.mmioDriveIn & 7: return driveIn
        // DFS 1.2 reads drive out in normal operation.
        case R.mmioDriveOut & 7: return driveOut
        case R.mmioClocks & 7: return mmioClocks
        case R.mmioData & 7: return mmioData
        default: return 0
        }
    }

    private func writeRegister(_ register: UInt8, _ value: UInt8) {
        let register = Int(register & 0x3F)
        if register < 32 {
            regs[register] = value
            return
        }
        switch register & 7 {
        case R.mmioDriveOut & 7:
            // Side select, manual head load (and so the motor), and drive
            // selects that override the command's.
            setDriveOut(value)
        case R.mmioClocks & 7:
            mmioClocks = value
        case R.mmioData & 7:
            mmioData = value
        default:
            break
        }
    }

    // MARK: Drive control

    private func driveOutRaise(_ bits: UInt8) {
        setDriveOut(driveOut | bits)
    }

    private func driveOutLower(_ bits: UInt8) {
        setDriveOut(driveOut & ~bits)
    }

    private func setDriveOut(_ value: UInt8) {
        // With both drives selected, select neither.
        let selectBits = value & DriveOut.selectFlags
        let drive: DiscDrive? = selectBits == DriveOut.select0 ? drives[0]
            : selectBits == DriveOut.select1 ? drives[1] : nil
        // LOAD HEAD gates each drive select (IC79 on the Model B).
        currentDrive = value & DriveOut.loadHead != 0 ? drive : nil

        if selectBits != driveOut & DriveOut.selectFlags {
            ready = false
            readyPulses = 0
            lastIndexTime = Int64.min / 2
            // Edges are counted from the new drive's level.
            stateIsIndexPulse = index
        }
        // LOAD HEAD is the drives' common motor line.
        for each in drives {
            if value & DriveOut.loadHead != 0 {
                each.startSpinning(at: time)
            } else {
                each.stopSpinning(at: time)
            }
        }
        currentDrive?.selectSide(upper: value & DriveOut.side != 0)
        driveOut = value
    }

    private func setState(_ newState: Phase) {
        phase = newState
        stateCount = 0
        if newState == .syncingForID || newState == .syncingForData {
            shiftRegister = 0
            numShifts = 0
        }
    }

    private func doSeek(_ context: Call) {
        if context != .unchanged { callContext = context }
        // The ROM busy-waits from here through the head load, so no index
        // pulse is acted on until the command picks its own handler.
        indexPulseCallback = .none
        var newTrack = Int(regs[R.internalParam1]) + Int(regs[R.internalSeekRetryCount])
        let trackRegs = driveOut & DriveOut.select1 != 0 ? R.badTrack1Drive1 : R.badTrack1Drive0
        // One more for each bad track covered. From the ROM, overflow and all.
        if newTrack > 0 {
            if Int(regs[trackRegs]) <= newTrack { newTrack = (newTrack + 1) & 0xFF }
            if Int(regs[trackRegs + 1]) <= newTrack { newTrack = (newTrack + 1) & 0xFF }
        }
        regs[R.internalSeekTarget1] = UInt8(truncatingIfNeeded: newTrack)
        regs[R.internalSeekTarget2] = UInt8(truncatingIfNeeded: newTrack)
        if newTrack >= 43 {
            driveOut |= DriveOut.lowHeadCurrent
        } else {
            driveOut &= ~DriveOut.lowHeadCurrent
        }
        // A seek to 0 pretends the current track is 255.
        let currentTrack = newTrack == 0 ? 255 : Int(regs[trackRegs + 2])
        didSeekStep = false

        if newTrack == currentTrack {
            doLoadHead()
            return
        }

        let steps = newTrack - currentTrack
        regs[R.internalSeekCount] = UInt8(truncatingIfNeeded: abs(steps))
        if steps > 0 {
            driveOut |= DriveOut.direction
        } else {
            driveOut &= ~DriveOut.direction
        }
        currentDrive?.notifySeekAmount(steps, stepMs: stepRateMs)

        // Step pulses are about 10us; leave them unobservable.
        driveOut &= ~DriveOut.step
        // The track registers are updated before the steps.
        regs[trackRegs + 2] = regs[R.internalSeekTarget2]
        if regs[R.mode] & Mode.singleActuator != 0 {
            regs[R.trackDrive0] = regs[R.internalSeekTarget2]
            regs[R.trackDrive1] = regs[R.internalSeekTarget2]
        }
        doSeekStep()
    }

    private func doSeekStep() {
        if (trk0 && regs[R.internalSeekTarget2] == 0) || regs[R.internalSeekCount] == 0 {
            if regs[R.internalSeekTarget2] == 0 && !trk0 {
                finishCommand(Result.trackZeroNotFound)
            } else {
                doLoadHead()
            }
            return
        }
        // A real step, so settle if the head is already loaded.
        didSeekStep = true
        regs[R.internalSeekCount] &-= 1
        currentDrive?.seekOneTrack(driveOut & DriveOut.direction != 0 ? 1 : -1)
        setTimer(.seekStep, ms: stepRateMs)
    }

    private var stepRateMs: Int {
        let rate = Int(regs[R.headStepRate])
        // 0 leaves it to the drive: say 3ms. Otherwise 2ms units for 5.25"
        // drives, going by timings on a real machine.
        return rate == 0 ? 3 : rate * 2
    }

    private func doLoadHead() {
        if didSeekStep { currentDrive?.notifySeekEnd() }
        var postSeekMs = 0
        // Head load time replaces settle time if there's both.
        if driveOut & DriveOut.loadHead == 0 {
            driveOutRaise(DriveOut.loadHead)
            // 4ms units, doubled for 5.25" drives.
            postSeekMs = 8 * Int(regs[R.headLoadUnload] & 0x0F)
        } else if didSeekStep {
            // 2ms units for 5.25" drives.
            postSeekMs = 2 * Int(regs[R.headSettleTime])
        }
        if postSeekMs != 0 {
            setTimer(.postSeek, ms: postSeekMs)
        } else {
            postSeekDispatch()
        }
    }

    private func postSeekDispatch() {
        timerState = .none
        guard checkDriveReady() else { return }
        switch callContext {
        case .seek:
            finishCommand(Result.ok)
        case .readID:
            indexPulseCallback = .startReadID
        case .format:
            setupSectorSize()
            indexPulseCallback = .startFormat
            checkWriteProtect()
        case .read, .write:
            setupSectorSize()
            startIndexPulseTimeout()
            startSyncingForHeader()
            if callContext == .write { checkWriteProtect() }
        default:
            break
        }
    }

    private func setupSectorSize() {
        let sectorSize = 128 << Int(regs[R.internalParam3] >> 5)
        let msb = UInt8(sectorSize >> 7 - 1)
        regs[R.internalCountLsb] = 0x80
        regs[R.internalCountMsb] = msb
        // R0 is trashed here.
        regs[R.internalCountMsbCopy] = msb
    }

    private func setTimer(_ newState: TimerState, ms: Int) {
        timerState = newState
        timerAt = time + Int64(ms) * 1000
    }

    private func startIndexPulseTimeout() {
        regs[R.internalIndexPulseCount] = 3
        indexPulseCallback = .timeout
    }

    private func startSyncingForHeader() {
        regs[R.internalHeaderPointer] = 0x0C
        setState(.syncingForID)
    }

    private func checkDriveReady() -> Bool {
        doReadDriveStatus()
        let mask: UInt8 = driveOut & DriveOut.select1 != 0 ? 0x40 : 0x04
        if regs[R.internalDriveInLatched] & mask == 0 {
            finishCommand(Result.driveNotReady)
            return false
        }
        return true
    }

    private func checkWriteProtect() {
        if regs[R.internalDriveInLatched] & 0x08 != 0 { finishCommand(Result.writeProtected) }
    }

    private func startCommand() {
        // Updates R21 and R27; R27 is later checked for write protect.
        doReadDriveStatus()
        paramCallback = .none

        // The MMIO clocks register really is used as temporary storage here.
        let selectBits = regs[R.internalCommand] & DriveOut.selectFlags
        mmioClocks = selectBits
        if selectBits != driveOut & DriveOut.selectFlags {
            // A change of drive select clears the other drive out bits bar
            // side select: the new drive's head isn't loaded, and dropping
            // LOAD HEAD stops both motors.
            setDriveOut(selectBits | driveOut & DriveOut.side)
        }
        // Mask out drive select and parameter count.
        regs[R.internalCommand] &= ~(DriveOut.selectFlags | 0x03)
        doCommandDispatch()
    }

    private var trk0: Bool { currentDrive?.track == 0 }

    private var driveIn: UInt8 {
        // On scarybeasts' machine bits 7 and 0 are always set.
        var value: UInt8 = 0x81
        // RDY0 and RDY1 are the Beeb's latch, which outlives a brief stop of the motor.
        if driveReady {
            if driveOut & DriveOut.select0 != 0 { value |= 0x04 }
            if driveOut & DriveOut.select1 != 0 { value |= 0x40 }
        }
        if let drive = currentDrive, drive.spinning {
            if drive.track == 0 { value |= 0x02 }
            if drive.writeProtected { value |= 0x08 }
            if drive.indexPulse { value |= 0x10 }
        }
        return value
    }

    @discardableResult
    private func doReadDriveStatus() -> UInt8 {
        var value = driveIn
        regs[R.internalDriveInCopy] = value
        regs[R.internalDriveInLatched] |= 0xBB
        value &= regs[R.internalDriveInLatched]
        regs[R.internalDriveInLatched] = value
        return value
    }

    private func doCommandDispatch() {
        switch internalCommand {
        case Command.readDriveStatus:
            setResult(doReadDriveStatus())
            regs[R.internalDriveInLatched] = regs[R.internalDriveInCopy]
            finishSimpleCommand()
        case Command.specify:
            regs[R.internalPointer] = regs[R.internalParam1]
            regs[R.internalParamCount] = 3
            paramCallback = .specify
        case Command.writeSpecialRegister:
            writeRegister(regs[R.internalParam1], regs[R.internalParam2])
            // A much simpler tidy-up than other commands.
            statusLower(Status.busy)
        case Command.readSpecialRegister:
            setResult(readRegister(regs[R.internalParam1]))
            finishSimpleCommand()
        case Command.readID:
            // The first dispatch seeks and waits for the index; re-dispatches
            // for further headers go straight to sync. A non-zero second
            // parameter is an undocumented way to skip the index wait.
            if regs[R.internalParam2] == 0 {
                doSeek(.readID)
            } else {
                startSyncingForHeader()
            }
        case Command.seek:
            doSeek(.seek)
        case Command.readData, Command.readDataAndDeleted, Command.verify,
             Command.scanData, Command.scanDataAndDeleted:
            doSeek(.read)
        case Command.writeData:
            regs[R.internalParamDataMarker] = IBMDiscFormat.dataMarkDataPattern
            doSeek(.write)
        case Command.writeDeletedData:
            regs[R.internalParamDataMarker] = IBMDiscFormat.deletedDataMarkDataPattern
            doSeek(.write)
        case Command.format:
            doSeek(.format)
        default:
            // 9 and 12 are unused; jsbeeb rejects them. Here they just end.
            finishSimpleCommand()
        }
    }

    private func finishSimpleCommand() {
        statusLower(Status.busy)
        stopIRQCallbacks()
        clearCallbacks()

        let headUnloadCount = regs[R.headLoadUnload] >> 4
        if headUnloadCount == 0 {
            spinDown()
        } else if headUnloadCount != 0x0F {
            // (0xF: never unload.)
            regs[R.internalIndexPulseCount] = headUnloadCount
            indexPulseCallback = .spindown
        }
    }

    private func finishCommand(_ result: UInt8) {
        if result != Result.ok {
            driveOutLower(DriveOut.direction | DriveOut.step | DriveOut.writeEnable)
        }
        setResult(result | regs[R.internalResult])
        // Command completion interrupt.
        statusRaise(Status.nmi)
        finishSimpleCommand()
    }

    /// Internal status bits 4 and 5 (internal only) enable data transfer interrupts.
    private var irqCallbacks: Bool { regs[R.internalStatus] & 0x30 == 0x30 }

    private func startIRQCallbacks() {
        regs[R.internalStatus] |= 0x30
    }

    private func stopIRQCallbacks() {
        regs[R.internalStatus] &= ~0x30
    }

    private func decrementCounter() -> Bool {
        regs[R.internalCountLsb] &-= 1
        if regs[R.internalCountLsb] != 0 { return false }
        regs[R.internalCountMsb] &-= 1
        if regs[R.internalCountMsb] != 0xFF {
            regs[R.internalCountLsb] = 0x80
            return false
        }
        regs[R.internalCountMsb] = 0
        stopIRQCallbacks()
        return true
    }

    private func clearCallbacks() {
        paramCallback = .none
        indexPulseCallback = .none
        timerState = .none
        timerAt = .max
        // The bit processor's read/write callback.
        setState(.idle)
    }

    private func spinDown() {
        driveOutLower(DriveOut.selectFlags | DriveOut.loadHead)
    }

    private func timerFired() {
        // r8 and r9 count milliseconds and are left zero after a busy wait.
        regs[R.internalMsCountHi] = 0
        regs[R.internalMsCountLo] = 0
        switch timerState {
        case .seekStep: doSeekStep()
        case .postSeek: postSeekDispatch()
        case .none: break
        }
    }

    private func doWriteRun(_ context: Call, _ byte: UInt8) {
        mmioData = byte
        mmioClocks = 0xFF
        crc = IBMDiscFormat.crcAdd(crc, mmioData)
        regs[R.internalWriteRunData] = mmioData
        driveOutRaise(DriveOut.writeEnable)
        callContext = context
        setState(.writeRun)
    }

    /// `numFFs` nil leaves the count registers as they are.
    private func writeFFsAnd00s(_ context: Call, _ numFFs: Int?) {
        if let numFFs {
            regs[R.internalCountLsb] = UInt8(truncatingIfNeeded: numFFs)
            regs[R.internalCountMsb] = 0
        }
        doWriteRun(context, 0xFF)
    }
}
