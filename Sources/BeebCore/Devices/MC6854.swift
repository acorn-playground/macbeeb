// The Motorola MC6854 (MC68B54) ADLC, as the BBC's Econet interface uses
// it: the registers, three-byte FIFOs and status as the CPU sees them, with
// the transmitter and receiver working a byte at a time against the line.
//
// From the datasheet's register model, checked against what Acorn's DNFS
// and ANFS do with it (BeebEm's annotated DNFS disassembly), MAME's mc6854
// (BSD-3-Clause, Antoine Mine) for the FIFOs and fields, and BeebEm's
// Econet.cpp (GPLv2+, Rob O'Donnell and Mike Wyatt) for prioritised status
// and which changes interrupt. The line carries whole bytes and flags, not
// bits: zero insertion, NRZI and the CRC's value aren't modelled, but a
// frame's check bytes take their time, so timing is a byte's.

/// What's on the line, a byte-time at a time.
public enum EconetSymbol: Sendable, Equatable, Codable {
    /// 01111110: between frames, or filling the line while a station holds
    /// it.
    case flag
    /// A byte of a frame.
    case byte(UInt8)
    /// One of a frame's two check bytes.
    case check
    /// Seven or more ones in a frame: the transmitter gave up on it.
    case abort
    /// Two stations transmitting at once: nothing intelligible.
    case garbage
}

/// The ADLC. Times are the machine's 2MHz cycles.
public final class MC6854 {
    // MARK: Registers

    public internal(set) var cr1: UInt8 = 0xC0
    public internal(set) var cr2: UInt8 = 0
    public internal(set) var cr3: UInt8 = 0
    public internal(set) var cr4: UInt8 = 0

    enum CR1 {
        static let addressControl: UInt8 = 0x01
        static let rie: UInt8 = 0x02
        static let tie: UInt8 = 0x04
        static let rdsr: UInt8 = 0x08
        static let tdsr: UInt8 = 0x10
        static let discontinue: UInt8 = 0x20
        static let rxReset: UInt8 = 0x40
        static let txReset: UInt8 = 0x80
    }

    enum CR2 {
        static let pse: UInt8 = 0x01
        static let twoByte: UInt8 = 0x02
        static let flagIdle: UInt8 = 0x04
        static let frameComplete: UInt8 = 0x08
        static let txLast: UInt8 = 0x10
        static let clearRx: UInt8 = 0x20
        static let clearTx: UInt8 = 0x40
        static let rts: UInt8 = 0x80
    }

    public enum SR1 {
        public static let rda: UInt8 = 0x01
        public static let s2rq: UInt8 = 0x02
        public static let loop: UInt8 = 0x04
        public static let fd: UInt8 = 0x08
        public static let cts: UInt8 = 0x10
        public static let tu: UInt8 = 0x20
        public static let tdra: UInt8 = 0x40
        public static let irq: UInt8 = 0x80
    }

    public enum SR2 {
        public static let ap: UInt8 = 0x01
        public static let fv: UInt8 = 0x02
        public static let idle: UInt8 = 0x04
        public static let abort: UInt8 = 0x08
        public static let error: UInt8 = 0x10
        public static let dcd: UInt8 = 0x20
        public static let overrun: UInt8 = 0x40
        public static let rda: UInt8 = 0x80
    }

    /// The status registers as the CPU reads them now.
    public private(set) var sr1: UInt8 = 0
    public private(set) var sr2: UInt8 = 0

    // MARK: Inputs and outputs

    /// /DCD: high when there's no clock on the network.
    public private(set) var noClock = true
    /// /CTS: high when it mustn't transmit (no clock, a collision, or RTS
    /// off, as the BBC wires it).
    public private(set) var notClearToSend = true
    /// Bit-time in cycles, from the network's clock.
    public private(set) var bitTime = 10
    var byteTime: Int { bitTime * 8 }
    /// Cycles the line takes to bring a symbol in (the network's delay; a
    /// real line's is a few microseconds). What arrives is that late, so the
    /// receiver counts idle from when it was enabled plus this: otherwise a
    /// reply that's prompt on the line looks late.
    var lineDelay = 0
    /// The IRQ output.
    public private(set) var irq = false
    /// Called when `irq` changes.
    var onIRQChange: (Bool) -> Void = { _ in }
    /// What the transmitter puts on the line, when RTS lets it out.
    var onTransmit: (EconetSymbol, UInt64) -> Void = { _, _ in }

    // MARK: Transmitter

    struct TxEntry: Equatable, Codable {
        var byte: UInt8
        var last: Bool
    }

    private(set) var txFIFO: [TxEntry] = []
    enum TxState: Equatable, Codable {
        /// No frame: flags or nothing.
        case idle
        /// In a frame: the next FIFO byte goes out.
        case data
        /// The check bytes to send, then the closing flag.
        case check(Int)
        case closingFlag
        /// The closing flag's out: the frame's complete.
        case complete
    }
    private(set) var txState = TxState.idle
    /// When the transmitter next puts a byte-time on the line.
    private(set) var nextTxTime: UInt64?
    private var underrun = false
    private var frameComplete = false

    /// RTS as it reaches the line: it stays on until a frame in progress
    /// has its closing flag, as the datasheet says.
    var rtsOut: Bool {
        cr2 & CR2.rts != 0 || txState != .idle || !txFIFO.isEmpty
    }

    // MARK: Receiver

    struct RxEntry: Equatable, Codable {
        var byte: UInt8
        var address: Bool
        /// The frame's last byte, and whether the frame was good.
        var end: FrameEnd?
    }

    enum FrameEnd: Equatable, Codable {
        case valid, error
    }

    private(set) var rxFIFO: [RxEntry] = []
    enum RxState: Equatable, Codable {
        /// Out of step: waiting for a flag.
        case hunting
        /// After a flag: the next byte is a frame's address.
        case synchronised
        /// In a frame (how many bytes and check bytes so far).
        case frame(bytes: Int, checks: Int)
        /// Discarding the rest of a frame (CR1's discontinue).
        case discarding
    }
    private(set) var rxState = RxState.hunting
    /// The last three byte-times of a frame, held back from the FIFO (nil
    /// for a check byte).
    private var pipeline: [UInt8?] = []
    /// The oldest in the pipeline is the frame's address.
    private var pipelineStartsFrame = false
    /// A frame ended with the FIFO already empty.
    private var pendingEnd: FrameEnd?
    private var frameValid = false
    private var frameError = false
    private var abortReceived = false
    private var overrun = false
    private var dcdLatched = false
    private var flagDetected = false
    /// When the line last carried anything (end of the last symbol).
    private var lineQuietSince: UInt64 = 0
    /// When the receiver came out of reset.
    private var receiverEnabledAt: UInt64 = 0

    // MARK: Interrupts

    /// The status bits (SR1, SR2) that went up since the CPU last dealt
    /// with them, and which keep IRQ asserted while they stay up.
    private var causes: (UInt8, UInt8) = (0, 0)
    private var shown: (UInt8, UInt8) = (0, 0)

    public init() {
        reset(now: 0)
    }

    /// Power on or the BBC's reset: both sections reset, everything clear.
    public func reset(now: UInt64) {
        cr1 = CR1.rxReset | CR1.txReset
        cr2 = 0
        cr3 = 0
        cr4 = 0
        txFIFO = []
        txState = .idle
        nextTxTime = nil
        underrun = false
        frameComplete = false
        resetReceiver()
        dcdLatched = noClock
        causes = (0, 0)
        shown = (0, 0)
        update(now: now)
    }

    private func resetReceiver() {
        pipeline = []
        rxFIFO = []
        rxState = .hunting
        pendingEnd = nil
        frameValid = false
        frameError = false
        abortReceived = false
        overrun = false
        flagDetected = false
    }

    // MARK: The line's state

    /// The clock's there or not, and its rate; whether a collision is on
    /// the line.
    func setLine(clock: Bool, bitTime: Int, collision: Bool, now: UInt64) {
        self.bitTime = max(1, bitTime)
        if clock != !noClock {
            noClock = !clock
            if noClock {
                dcdLatched = true
                // No clock, no frame.
                if case .frame = rxState { abortReceived = true }
                rxState = .hunting
            }
        }
        self.collision = collision
        if collision {
            ctsLatched = true
        }
        updateCTS()
        if clock { scheduleTransmitter(now: now) }
        update(now: now)
    }

    /// A collision raised /CTS: it shows until the CPU clears it.
    private var ctsLatched = false
    private var collision = false

    /// /CTS, as the BBC's collision detection makes it: high without a
    /// clock, in a collision, or while /RTS is off (it stays on to the end
    /// of a frame).
    private func updateCTS() {
        notClearToSend = noClock || collision || !rtsOut
    }

    // MARK: CPU interface

    public func read(_ register: Int, now: UInt64) -> UInt8 {
        switch register & 3 {
        case 0:
            return sr1
        case 1:
            return sr2
        default:
            guard cr1 & CR1.rxReset == 0, !rxFIFO.isEmpty else { return 0 }
            let entry = rxFIFO.removeFirst()
            if let end = entry.end {
                finishFrame(end)
            }
            update(now: now)
            return entry.byte
        }
    }

    /// What reading `register` would give, without reading it.
    public func peek(_ register: Int) -> UInt8 {
        switch register & 3 {
        case 0: sr1
        case 1: sr2
        default: rxFIFO.first?.byte ?? 0
        }
    }

    public func write(_ register: Int, _ value: UInt8, now: UInt64) {
        switch register & 3 {
        case 0:
            let wasRxReset = cr1 & CR1.rxReset != 0
            cr1 = value
            if value & CR1.discontinue != 0 {
                rxFIFO = []
                pendingEnd = nil
                if case .frame = rxState { rxState = .discarding }
            }
            if value & CR1.rxReset != 0 {
                resetReceiver()
                clearCauses(sr1: SR1.rda | SR1.s2rq | SR1.fd, sr2: 0xFF)
            } else if wasRxReset {
                receiverEnabledAt = now
                rxState = .hunting
            }
            if value & CR1.txReset != 0 {
                txFIFO = []
                txState = .idle
                nextTxTime = nil
                underrun = false
                frameComplete = false
                clearCauses(sr1: SR1.tu | SR1.tdra | SR1.cts, sr2: 0)
            } else {
                scheduleTransmitter(now: now)
            }
        case 1:
            if cr1 & CR1.addressControl != 0 {
                cr3 = value
            } else {
                cr2 = value & ~(CR2.txLast | CR2.clearRx | CR2.clearTx)
                if value & CR2.txLast != 0 {
                    markLast()
                }
                if value & CR2.clearRx != 0 {
                    frameValid = false
                    frameError = false
                    abortReceived = false
                    overrun = false
                    flagDetected = false
                    dcdLatched = noClock
                    clearCauses(sr1: SR1.s2rq | SR1.fd, sr2: 0x7F)
                }
                if value & CR2.clearTx != 0 {
                    underrun = false
                    frameComplete = false
                    ctsLatched = false
                    clearCauses(sr1: SR1.tu | SR1.tdra | SR1.cts, sr2: 0)
                }
                updateCTS()
                scheduleTransmitter(now: now)
            }
        case 2:
            push(value, last: false, now: now)
        default:
            if cr1 & CR1.addressControl != 0 {
                cr4 = value
                if value & 0x20 != 0 {
                    abortTransmission(now: now)
                }
            } else {
                push(value, last: true, now: now)
            }
        }
        update(now: now)
    }

    // MARK: Transmitter

    private func push(_ byte: UInt8, last: Bool, now: UInt64) {
        guard cr1 & CR1.txReset == 0 else { return }
        // A full FIFO loses the byte (the CPU should have waited for TDRA).
        guard txFIFO.count < 3 else { return }
        txFIFO.append(TxEntry(byte: byte, last: last))
        scheduleTransmitter(now: now)
    }

    private func markLast() {
        guard !txFIFO.isEmpty else { return }
        txFIFO[txFIFO.count - 1].last = true
    }

    private func abortTransmission(now: UInt64) {
        if txState != .idle {
            emit(.abort, at: nextTxTime ?? now)
        }
        txState = .idle
        txFIFO = []
    }

    /// Starts the transmitter's byte clock if it has anything to do.
    private func scheduleTransmitter(now: UInt64) {
        guard nextTxTime == nil, transmitterBusy else { return }
        // It starts on the next bit.
        nextTxTime = now + UInt64(bitTime)
    }

    private var transmitterBusy: Bool {
        guard cr1 & CR1.txReset == 0, !noClock else { return false }
        return txState != .idle || !txFIFO.isEmpty || (cr2 & CR2.rts != 0 && cr2 & CR2.flagIdle != 0)
    }

    /// One byte-time of transmission.
    private func transmit(at time: UInt64) {
        if txState == .complete {
            frameComplete = true
            txState = .idle
        }
        switch txState {
        case .idle:
            if !txFIFO.isEmpty {
                // The opening flag.
                emit(.flag, at: time)
                txState = .data
            } else if cr2 & CR2.rts != 0 && cr2 & CR2.flagIdle != 0 {
                emit(.flag, at: time)
            }
        case .data:
            if txFIFO.isEmpty {
                underrun = true
                emit(.abort, at: time)
                txState = .idle
            } else {
                let entry = txFIFO.removeFirst()
                emit(.byte(entry.byte), at: time)
                if entry.last {
                    txState = .check(2)
                }
            }
        case .check(let left):
            emit(.check, at: time)
            txState = left > 1 ? .check(left - 1) : .closingFlag
        case .closingFlag:
            emit(.flag, at: time)
            // Another frame waiting starts straight away (its opening flag
            // is this closing one).
            if txFIFO.isEmpty {
                txState = .complete
            } else {
                frameComplete = true
                txState = .data
            }
        case .complete:
            break
        }
        nextTxTime = transmitterBusy ? time + UInt64(byteTime) : nil
    }

    private func emit(_ symbol: EconetSymbol, at time: UInt64) {
        if rtsOut {
            onTransmit(symbol, time)
        }
    }

    // MARK: Receiver

    /// A symbol's first bit is on the line: it's not idle.
    func lineBusy(at time: UInt64) {
        lineQuietSince = max(lineQuietSince, time + UInt64(byteTime))
        update(now: time)
    }

    /// A symbol from the line, at `time` (when its last bit's in).
    func receive(_ symbol: EconetSymbol, at time: UInt64) {
        lineQuietSince = time
        guard cr1 & CR1.rxReset == 0, !noClock else {
            update(now: time)
            return
        }
        switch symbol {
        case .flag:
            if cr3 & 0x10 != 0 { flagDetected = true }
            if case .frame = rxState {
                // What's still in the shift register: the last byte, if the
                // last two were the check bytes.
                let valid = pipeline.count == 3 && pipeline[1] == nil && pipeline[2] == nil && pipeline[0] != nil
                if valid, let byte = pipeline[0] {
                    store(RxEntry(byte: byte, address: pipelineStartsFrame, end: .valid))
                } else {
                    endFrame(.error)
                }
            }
            pipeline = []
            rxState = .synchronised
        case .byte, .check:
            let byte: UInt8? = if case .byte(let b) = symbol { b } else { nil }
            switch rxState {
            case .synchronised:
                pipeline = [byte]
                pipelineStartsFrame = true
                rxState = .frame(bytes: 1, checks: 0)
            case .frame:
                pipeline.append(byte)
                // A byte reaches the FIFO three byte-times after it arrives
                // (two check bytes and the closing flag could follow it).
                if pipeline.count > 3 {
                    let oldest = pipeline.removeFirst()
                    if let oldest {
                        store(RxEntry(byte: oldest, address: pipelineStartsFrame, end: nil))
                    } else {
                        // A check byte with data after it: not a frame.
                        endFrame(.error)
                        rxState = .hunting
                    }
                    pipelineStartsFrame = false
                }
            case .hunting, .discarding:
                break
            }
        case .abort:
            if case .frame = rxState {
                abortReceived = true
            }
            pipeline = []
            rxState = .hunting
        case .garbage:
            if case .frame = rxState {
                endFrame(.error)
            }
            pipeline = []
            rxState = .hunting
        }
        update(now: time)
    }

    private func store(_ entry: RxEntry) {
        // Nothing more until the last frame's status has been seen.
        guard !frameValid && pendingEnd == nil else { return }
        if rxFIFO.contains(where: { $0.end != nil }) { return }
        guard rxFIFO.count < 3 else {
            overrun = true
            return
        }
        rxFIFO.append(entry)
    }

    private func endFrame(_ end: FrameEnd) {
        if let index = rxFIFO.lastIndex(where: { _ in true }), rxFIFO[index].end == nil {
            rxFIFO[index].end = end
        } else {
            pendingEnd = end
        }
    }

    private func finishFrame(_ end: FrameEnd) {
        if end == .valid { frameValid = true } else { frameError = true }
    }

    // MARK: Time

    /// When something next happens without the CPU: a byte-time of
    /// transmission, or the line going idle.
    var nextEventTime: UInt64? {
        // (No array: this runs for every station every quantum.)
        switch (nextTxTime, idleDeadline) {
        case (let tx?, let idle?): min(tx, idle)
        case (let tx?, nil): tx
        case (nil, let idle?): idle
        case (nil, nil): nil
        }
    }

    /// When the line will have been quiet for 15 bits (the receiver's idle).
    private var idleDeadline: UInt64? {
        guard cr1 & CR1.rxReset == 0, !noClock, !idleKnown else { return nil }
        return idleFrom + UInt64(bitTime * 15)
    }

    /// When the line went quiet, as the receiver can tell.
    private var idleFrom: UInt64 { max(lineQuietSince, receiverEnabledAt + UInt64(lineDelay)) }

    private var idleKnown = false

    /// Runs whatever's due by `now`.
    func advance(to now: UInt64) {
        while let time = nextTxTime, time <= now {
            transmit(at: time)
        }
        update(now: now)
    }

    // MARK: Status

    private func update(now: UInt64) {
        let enabled = cr1 & CR1.rxReset == 0 && !noClock
        let idle = enabled && now >= idleFrom + UInt64(bitTime * 15)
        if idle && !idleKnown, case .frame = rxState {
            // Idle in a frame is an abort.
            abortReceived = true
        }
        if idle { rxState = .hunting }
        idleKnown = idle

        updateCTS()
        if let end = pendingEnd, rxFIFO.isEmpty {
            pendingEnd = nil
            finishFrame(end)
        }

        var s2: UInt8 = 0
        if rxFIFO.first?.address == true { s2 |= SR2.ap }
        let lastAtHead = rxFIFO.first?.end
        if frameValid || lastAtHead == .valid { s2 |= SR2.fv }
        if frameError || lastAtHead == .error { s2 |= SR2.error }
        if idle { s2 |= SR2.idle }
        if abortReceived { s2 |= SR2.abort }
        if dcdLatched || noClock { s2 |= SR2.dcd }
        if overrun { s2 |= SR2.overrun }
        let twoByte = cr2 & CR2.twoByte != 0
        if let head = rxFIFO.first, !twoByte || rxFIFO.count >= 2 || head.end != nil {
            s2 |= SR2.rda
        }
        if cr2 & CR2.pse != 0 {
            if s2 & (SR2.fv | SR2.abort | SR2.error | SR2.dcd | SR2.overrun) != 0 {
                s2 &= ~(SR2.ap | SR2.idle | SR2.rda)
            } else if s2 & SR2.idle != 0 {
                s2 &= ~(SR2.ap | SR2.rda)
            } else if s2 & SR2.ap != 0 {
                s2 &= ~SR2.rda
            }
        }

        var s1: UInt8 = 0
        if s2 & SR2.rda != 0 { s1 |= SR1.rda }
        if s2 & 0x7F != 0 { s1 |= SR1.s2rq }
        if flagDetected { s1 |= SR1.fd }
        if notClearToSend || ctsLatched { s1 |= SR1.cts }
        if underrun { s1 |= SR1.tu }
        if cr2 & CR2.frameComplete != 0 {
            if frameComplete { s1 |= SR1.tdra }
        } else if cr1 & CR1.txReset == 0 && s1 & SR1.cts == 0 && txFIFO.count <= (twoByte ? 1 : 2) {
            s1 |= SR1.tdra
        }

        // Interrupts: a status bit going up, with its section's interrupts
        // enabled, asserts IRQ until the bit goes down or the CPU clears it.
        causes.0 |= s1 & ~shown.0 & ~SR1.irq
        causes.1 |= s2 & ~shown.1
        causes.0 &= s1
        causes.1 &= s2
        shown = (s1, s2)
        var mask1: UInt8 = 0
        var mask2: UInt8 = 0
        if cr1 & CR1.rie != 0 {
            mask1 |= SR1.fd | (cr1 & CR1.rdsr == 0 ? SR1.rda : 0)
            mask2 = 0x7F
        }
        if cr1 & CR1.tie != 0 {
            mask1 |= SR1.cts | SR1.tu | (cr1 & CR1.tdsr == 0 ? SR1.tdra : 0)
        }
        let asserted = causes.0 & mask1 != 0 || causes.1 & mask2 != 0
        if asserted { s1 |= SR1.irq }
        sr1 = s1
        sr2 = s2
        if asserted != irq {
            irq = asserted
            onIRQChange(asserted)
        }
    }

    /// The CPU's cleared these: they no longer cause interrupts, even if
    /// they stay up (a level like DCD or idle doesn't interrupt again).
    private func clearCauses(sr1 bits1: UInt8, sr2 bits2: UInt8) {
        causes.0 &= ~bits1
        causes.1 &= ~bits2
    }
}

// MARK: Save states

extension MC6854 {
    /// Everything about the ADLC that changes, for save states and rewind.
    struct State: Codable, Sendable {
        var cr1, cr2, cr3, cr4, sr1, sr2: UInt8
        var noClock, notClearToSend: Bool
        var bitTime: Int
        var irq: Bool
        var txFIFO: [TxEntry]
        var txState: TxState
        var nextTxTime: UInt64?
        var underrun, frameComplete: Bool
        var rxFIFO: [RxEntry]
        var rxState: RxState
        var pipeline: [UInt8?]
        var pipelineStartsFrame: Bool
        var pendingEnd: FrameEnd?
        var frameValid, frameError, abortReceived, overrun, dcdLatched, flagDetected: Bool
        var lineQuietSince, receiverEnabledAt: UInt64
        var causes1, causes2, shown1, shown2: UInt8
        var ctsLatched, collision, idleKnown: Bool
    }

    var state: State {
        State(cr1: cr1, cr2: cr2, cr3: cr3, cr4: cr4, sr1: sr1, sr2: sr2, noClock: noClock, notClearToSend: notClearToSend,
              bitTime: bitTime, irq: irq, txFIFO: txFIFO, txState: txState, nextTxTime: nextTxTime, underrun: underrun,
              frameComplete: frameComplete, rxFIFO: rxFIFO, rxState: rxState, pipeline: pipeline,
              pipelineStartsFrame: pipelineStartsFrame, pendingEnd: pendingEnd, frameValid: frameValid, frameError: frameError,
              abortReceived: abortReceived, overrun: overrun, dcdLatched: dcdLatched, flagDetected: flagDetected,
              lineQuietSince: lineQuietSince, receiverEnabledAt: receiverEnabledAt, causes1: causes.0, causes2: causes.1,
              shown1: shown.0, shown2: shown.1, ctsLatched: ctsLatched, collision: collision, idleKnown: idleKnown)
    }

    /// Takes up a saved state (the IRQ line as it was: the module's told).
    func restore(_ s: State) {
        cr1 = s.cr1; cr2 = s.cr2; cr3 = s.cr3; cr4 = s.cr4; sr1 = s.sr1; sr2 = s.sr2
        noClock = s.noClock; notClearToSend = s.notClearToSend; bitTime = s.bitTime; irq = s.irq
        txFIFO = s.txFIFO; txState = s.txState; nextTxTime = s.nextTxTime; underrun = s.underrun; frameComplete = s.frameComplete
        rxFIFO = s.rxFIFO; rxState = s.rxState; pipeline = s.pipeline; pipelineStartsFrame = s.pipelineStartsFrame
        pendingEnd = s.pendingEnd; frameValid = s.frameValid; frameError = s.frameError; abortReceived = s.abortReceived
        overrun = s.overrun; dcdLatched = s.dcdLatched; flagDetected = s.flagDetected
        lineQuietSince = s.lineQuietSince; receiverEnabledAt = s.receiverEnabledAt
        causes = (s.causes1, s.causes2); shown = (s.shown1, s.shown2)
        ctsLatched = s.ctsLatched; collision = s.collision; idleKnown = s.idleKnown
    }
}
