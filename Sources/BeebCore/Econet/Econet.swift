// A machine's Econet module: the ADLC, the station number links, and the
// flip-flop that gates the ADLC's interrupt onto NMI (INTOFF on an access
// to the station number, INTON on a read of &FE20 on the B, &FE3C on the
// Master).

/// The Econet interface fitted to one machine.
public final class Econet {
    public let adlc = MC6854()
    /// The station number links.
    public let station: UInt8
    /// Whether the ADLC's interrupt reaches NMI (INTON) or not (INTOFF).
    public private(set) var nmiEnabled = false
    /// The line it's plugged into, if any. Without one there's no clock.
    weak var bus: EconetBus? {
        didSet { adlc.lineDelay = bus?.delay ?? 0 }
    }
    /// What's arrived from the line, by the time (in the machine's cycles)
    /// it reaches the ADLC.
    /// (A nil symbol is the start of one: the line's busy from its first
    /// bit, though the byte isn't in until its last.)
    private var inbox: [(time: UInt64, symbol: EconetSymbol?)] = []
    private var inboxNext = 0
    /// What the ADLC has sent this quantum, at the machine's cycles.
    var outbox: [(time: UInt64, symbol: EconetSymbol)] = []
    /// When something next happens: the machine runs `advance` then.
    public private(set) var nextEvent: UInt64 = .max
    /// The NMI line out.
    var onNMI: (Bool) -> Void = { _ in }
    /// Counts NMIs the ADLC has raised, for tests and the inspector.
    public private(set) var nmiCount = 0
    /// When the station last sent a frame's byte (the machine's cycles):
    /// for knowing when it's finished loading something.
    public private(set) var lastTransmitted: UInt64 = 0
    /// When a frame for this station last arrived (the machine's cycles): a
    /// station waiting for a busy server is quiet, but not finished.
    public private(set) var lastAddressed: UInt64 = 0
    /// Whether the line's last symbol was a flag: the next byte starts a
    /// frame, with its destination.
    private var frameStarting = false
    /// Sees every CPU access (for tests and debugging).
    var accessObserver: ((String) -> Void)?

    init(station: UInt8) {
        self.station = station
        adlc.onTransmit = { [unowned self] symbol, time in
            outbox.append((time, symbol))
            if symbol != .flag { lastTransmitted = time }
        }
        adlc.onIRQChange = { [unowned self] _ in updateNMI() }
        adlc.setLine(clock: false, bitTime: 10, collision: false, now: 0)
    }

    /// The BBC's reset (Break and power on): the ADLC resets, and NMI is
    /// gated off.
    func reset(now: UInt64) {
        nmiEnabled = false
        adlc.reset(now: now)
        updateNMI()
        reschedule()
    }

    // MARK: The CPU's side

    /// Any access to the station number (&FE18 on the B, &FE38 on the
    /// Master): INTOFF, and the links.
    func readStation(now: UInt64) -> UInt8 {
        advance(to: now)
        if nmiEnabled { accessObserver?("\(now) INTOFF (station)") }
        nmiEnabled = false
        updateNMI()
        return station
    }

    func intoff(now: UInt64) {
        advance(to: now)
        nmiEnabled = false
        updateNMI()
    }

    /// A read of &FE20 (the Master's &FE3C): INTON. An interrupt already
    /// waiting raises NMI straight away.
    func inton(now: UInt64) {
        advance(to: now)
        if !nmiEnabled { accessObserver?("\(now) INTON") }
        nmiEnabled = true
        updateNMI()
    }

    func read(_ register: Int, now: UInt64) -> UInt8 {
        advance(to: now)
        let value = adlc.read(register, now: now)
        reschedule()
        accessObserver?("\(now) R\(register) = \(String(value, radix: 16)) irq \(adlc.irq)")
        return value
    }

    func write(_ register: Int, _ value: UInt8, now: UInt64) {
        advance(to: now)
        adlc.write(register, value, now: now)
        reschedule()
        accessObserver?("\(now) W\(register) \(String(value, radix: 16)) -> sr1 \(String(adlc.sr1, radix: 16)) sr2 \(String(adlc.sr2, radix: 16)) irq \(adlc.irq)")
    }

    private var nmiAsserted = false

    private func updateNMI() {
        let asserted = adlc.irq && nmiEnabled
        guard asserted != nmiAsserted else { return }
        accessObserver?("NMI \(asserted)")
        nmiAsserted = asserted
        if asserted { nmiCount += 1 }
        onNMI(asserted)
    }

    // MARK: The line's side

    /// Runs the ADLC and the line up to `now`, in time order.
    public func advance(to now: UInt64) {
        while true {
            let symbolTime = inboxNext < inbox.count ? inbox[inboxNext].time : .max
            let adlcTime = adlc.nextEventTime ?? .max
            let time = min(symbolTime, adlcTime)
            guard time <= now else { break }
            if symbolTime <= adlcTime {
                let symbol = inbox[inboxNext].symbol
                inboxNext += 1
                adlc.advance(to: symbolTime)
                if let symbol {
                    adlc.receive(symbol, at: symbolTime)
                } else {
                    adlc.lineBusy(at: symbolTime)
                }
            } else {
                adlc.advance(to: adlcTime)
            }
        }
        if inboxNext > 64 {
            inbox.removeFirst(inboxNext)
            inboxNext = 0
        }
        adlc.advance(to: now)
        reschedule()
    }

    private func reschedule() {
        let symbolTime = inboxNext < inbox.count ? inbox[inboxNext].time : .max
        nextEvent = min(symbolTime, adlc.nextEventTime ?? .max)
    }

    /// Symbols from the line, at the machine's cycles when they're in (in
    /// time order, all still to come).
    func deliver(_ symbols: [(time: UInt64, symbol: EconetSymbol)]) {
        let byteTime = UInt64(adlc.bitTime * 8)
        var events: [(time: UInt64, symbol: EconetSymbol?)] = []
        for (time, symbol) in symbols {
            events.append((time - byteTime, nil))
            events.append((time, symbol))
            if case .byte(let destination) = symbol, frameStarting, destination == station {
                lastAddressed = time
            }
            frameStarting = symbol == .flag
        }
        events.sort { $0.time < $1.time }
        // Merge with what's still to come (deliveries overlap by a byte).
        var pending = Array(inbox[inboxNext...]) + events
        pending.sort { $0.time < $1.time }
        inbox = pending
        inboxNext = 0
        reschedule()
    }

    /// The line's clock and whether this station's transmission collided.
    func setLine(clock: Bool, bitTime: Int, collision: Bool, now: UInt64) {
        advance(to: now)
        adlc.setLine(clock: clock, bitTime: bitTime, collision: collision, now: now)
        reschedule()
    }

    /// Unplugged: no clock, and nothing more arrives.
    func unplug(now: UInt64) {
        inbox.removeAll()
        inboxNext = 0
        outbox.removeAll()
        setLine(clock: false, bitTime: adlc.bitTime, collision: false, now: now)
    }

    // MARK: Reporting

    /// The module's state, for agents and the inspector.
    public func statusReport() -> String {
        let a = adlc
        func bits(_ value: UInt8, _ names: [String]) -> String {
            let set = (0..<8).filter { value & (1 << $0) != 0 }.map { names[$0] }
            return String(format: "&%02X", value) + (set.isEmpty ? "" : " (" + set.joined(separator: " ") + ")")
        }
        var lines = [
            "station: \(station)",
            "NMI: \(nmiEnabled ? "enabled (INTON)" : "disabled (INTOFF)"), \(nmiCount) raised",
            "line: \(bus == nil ? "not plugged in" : "plugged in"), " + (a.noClock ? "no clock (/DCD high)" : "clock, bit time \(a.bitTime) cycles"),
            "CR1 " + bits(a.cr1, ["AC", "RIE", "TIE", "RDSR", "TDSR", "discontinue", "RX reset", "TX reset"]),
            "CR2 " + bits(a.cr2, ["PSE", "2-byte", "flag idle", "FC", "TX last", "clear RX", "clear TX", "RTS"]),
            "CR3 " + bits(a.cr3, ["LCF", "CEX", "AEX", "01/11 idle", "FDSE", "loop", "test", "DTR"]),
            "CR4 " + bits(a.cr4, ["double flag", "TX len", "TX len", "RX len", "RX len", "abort", "abort ext", "NRZ"]),
            "SR1 " + bits(a.sr1, ["RDA", "S2RQ", "loop", "FD", "CTS", "TU", "TDRA/FC", "IRQ"]),
            "SR2 " + bits(a.sr2, ["AP", "FV", "idle", "abort", "error", "DCD", "overrun", "RDA"]),
            "/CTS: \(a.notClearToSend ? "high (mustn't send)" : "low (clear to send)"), RTS out: \(a.rtsOut ? "on" : "off")",
            "transmitter: \(a.txState), FIFO \(a.txFIFO.map { String(format: "%02X", $0.byte) + ($0.last ? "(last)" : "") })",
            "receiver: \(a.rxState), FIFO \(a.rxFIFO.map { String(format: "%02X", $0.byte) + ($0.address ? "(address)" : "") + ($0.end != nil ? "(end)" : "") })",
        ]
        lines.append("IRQ: \(a.irq ? "asserted" : "off")")
        return lines.joined(separator: "\n")
    }
}
