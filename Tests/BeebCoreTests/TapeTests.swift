// The 6850 ACIA against its datasheet, UEF and CSW parsing, and tapes played
// through the serial ULA into the ACIA as the OS's cassette filing system
// reads them.

import Foundation
import Testing
@testable import BeebCore

/// A frame's bits: start, data from the least significant, parity, stop.
private func frameBits(_ byte: UInt8, dataBits: Int = 8, parity: Tape.Framing.Parity = .none,
                       stopBits: Int = 1) -> [Bool] {
    var bits = [false]
    bits += (0..<dataBits).map { byte >> $0 & 1 != 0 }
    let ones = bits.filter { $0 }.count
    switch parity {
    case .none: break
    case .even: bits.append(ones & 1 != 0)
    case .odd: bits.append(ones & 1 == 0)
    }
    return bits + [Bool](repeating: true, count: stopBits)
}

private extension MC6850 {
    /// Holds RxD at each level for `divide` receive clocks.
    mutating func receive(_ bits: [Bool], divide: Int = 16) {
        for bit in bits {
            for _ in 0..<divide { clockReceive(bit) }
        }
    }

    /// TxD at the middle of each bit time for `count` bits.
    mutating func transmit(bits count: Int, divide: Int = 16) -> (bits: [Bool], sent: [UInt8]) {
        var bits: [Bool] = []
        var sent: [UInt8] = []
        for _ in 0..<count {
            for clock in 0..<divide {
                if let byte = clockTransmit() { sent.append(byte) }
                if clock == divide / 2 { bits.append(txd) }
            }
        }
        return (bits, sent)
    }
}

/// Register reads, which have side effects, for use in `#expect`.
private func readStatus(_ acia: inout MC6850) -> UInt8 { acia.read(0) }
private func readData(_ acia: inout MC6850) -> UInt8 { acia.read(1) }

/// Control register values.
private enum Control {
    static let masterReset: UInt8 = 0x03
    /// /16, 8N1, RTS low, no TX IRQ, RX IRQ: the OS's cassette read at 1200
    /// baud is &D5 (the same with RTS high).
    static let div16_8N1_RIE: UInt8 = 0x95
    static let div16_8N1: UInt8 = 0x15
    static let div16_7E1: UInt8 = 0x09
    static let div16_7O2: UInt8 = 0x05
    static let div64_8N1: UInt8 = 0x16
    static let txIRQ: UInt8 = 0x20
}

struct MC6850Tests {
    func resetACIA(_ control: UInt8 = Control.div16_8N1_RIE) -> MC6850 {
        var acia = MC6850()
        acia.write(0, Control.masterReset)
        acia.write(0, control)
        return acia
    }

    @Test func masterResetReadsAsTheInputsOnly() {
        var acia = MC6850()
        acia.setCTS(true)
        acia.write(0, Control.masterReset)
        #expect(readStatus(&acia) == MC6850.Status.cts)
        acia.setCTS(false)
        #expect(readStatus(&acia) == 0)
        acia.write(0, Control.div16_8N1)
        #expect(readStatus(&acia) == MC6850.Status.tdre)
    }

    @Test func masterResetClearsReceivedDataAndIRQ() {
        var acia = resetACIA()
        acia.receive(frameBits(0x42))
        #expect(acia.irq)
        acia.write(0, Control.masterReset)
        #expect(!acia.irq)
        acia.write(0, Control.div16_8N1_RIE)
        #expect(readStatus(&acia) == MC6850.Status.tdre)
    }

    @Test func receivesAFrameAtDivide16() {
        var acia = resetACIA()
        acia.receive([true, true] + frameBits(0xA5))
        #expect(acia.peek(0) == MC6850.Status.rdrf | MC6850.Status.tdre | MC6850.Status.irq)
        #expect(readData(&acia) == 0xA5)
        #expect(readStatus(&acia) == MC6850.Status.tdre)
        #expect(!acia.irq)
    }

    @Test func receivesAFrameAtDivide64AndDivide1() {
        var acia = resetACIA(Control.div64_8N1)
        acia.receive(frameBits(0x3C), divide: 64)
        #expect(readData(&acia) == 0x3C)
        #expect(!acia.irq, "RIE clear")

        acia = resetACIA(0x14)
        acia.receive(frameBits(0xC3), divide: 1)
        #expect(acia.peek(0) & MC6850.Status.rdrf != 0)
        #expect(readData(&acia) == 0xC3)
    }

    @Test func receivesBackToBackFramesOffTheClockGrid() {
        var acia = resetACIA()
        // Start 5 clocks into a /16 period: the receiver syncs on the edge.
        for _ in 0..<5 { acia.clockReceive(true) }
        var received: [UInt8] = []
        for byte: UInt8 in [0x00, 0xFF, 0x2A, 0x55] {
            acia.receive(frameBits(byte))
            if acia.peek(0) & MC6850.Status.rdrf != 0 { received.append(acia.read(1)) }
        }
        #expect(received == [0x00, 0xFF, 0x2A, 0x55])
    }

    @Test func ignoresAStartBitGlitch() {
        var acia = resetACIA()
        for _ in 0..<5 { acia.clockReceive(false) }
        acia.receive([Bool](repeating: true, count: 12))
        #expect(acia.peek(0) & MC6850.Status.rdrf == 0)
    }

    @Test func checksParity() {
        var acia = resetACIA(Control.div16_7E1)
        acia.receive(frameBits(0x41, dataBits: 7, parity: .even))
        #expect(acia.peek(0) & MC6850.Status.pe == 0)
        #expect(readData(&acia) == 0x41)
        acia.receive(frameBits(0x41, dataBits: 7, parity: .odd))
        #expect(acia.peek(0) & MC6850.Status.pe != 0)
        #expect(readData(&acia) == 0x41)

        acia = resetACIA(Control.div16_7O2)
        acia.receive(frameBits(0x43, dataBits: 7, parity: .odd, stopBits: 2))
        #expect(acia.peek(0) & (MC6850.Status.pe | MC6850.Status.fe) == 0)
        #expect(readData(&acia) == 0x43)
    }

    @Test func flagsAMissingStopBit() {
        var acia = resetACIA()
        var bits = frameBits(0x81)
        bits[9] = false
        acia.receive(bits + [Bool](repeating: true, count: 10))
        #expect(acia.peek(0) & MC6850.Status.fe != 0)
        #expect(readData(&acia) == 0x81)
        acia.receive(frameBits(0x01))
        #expect(acia.peek(0) & MC6850.Status.fe == 0)
        #expect(readData(&acia) == 0x01)
    }

    @Test func overrunShowsAfterTheGoodCharacterIsRead() {
        var acia = resetACIA()
        acia.receive(frameBits(0x11) + frameBits(0x22))
        #expect(acia.peek(0) & (MC6850.Status.rdrf | MC6850.Status.ovrn) == MC6850.Status.rdrf)
        #expect(readData(&acia) == 0x11)
        #expect(acia.peek(0) & (MC6850.Status.rdrf | MC6850.Status.ovrn) == MC6850.Status.rdrf | MC6850.Status.ovrn)
        #expect(acia.irq)
        _ = acia.read(1)
        #expect(acia.peek(0) & (MC6850.Status.rdrf | MC6850.Status.ovrn) == 0)
        #expect(!acia.irq)
        acia.receive(frameBits(0x33))
        #expect(readData(&acia) == 0x33)
    }

    @Test func dcdRisingLatchesAndInterrupts() {
        var acia = resetACIA()
        acia.setDCD(true)
        #expect(acia.irq)
        #expect(acia.peek(0) & MC6850.Status.dcd != 0)
        acia.setDCD(false)
        // Latched until the data register is read.
        #expect(readStatus(&acia) & MC6850.Status.dcd != 0)
        #expect(acia.irq)
        _ = acia.read(1)
        #expect(readStatus(&acia) & MC6850.Status.dcd == 0)
        #expect(!acia.irq)

        // Read while still high: the flag follows the input, no new IRQ.
        acia.setDCD(true)
        _ = acia.read(1)
        #expect(!acia.irq)
        #expect(readStatus(&acia) & MC6850.Status.dcd != 0)
        acia.setDCD(false)
        #expect(readStatus(&acia) & MC6850.Status.dcd == 0)

        // Without RIE, the flag but no IRQ.
        acia = resetACIA(Control.div16_8N1)
        acia.setDCD(true)
        #expect(!acia.irq)
        #expect(readStatus(&acia) & MC6850.Status.dcd != 0)
    }

    @Test func highDCDHoldsTheReceiverIdle() {
        var acia = resetACIA()
        acia.setDCD(true)
        _ = acia.read(1)
        acia.receive(frameBits(0x00))
        #expect(acia.peek(0) & MC6850.Status.rdrf == 0)
        acia.setDCD(false)
        acia.receive(frameBits(0x00))
        #expect(readData(&acia) == 0x00)
    }

    @Test func transmitsAFrame() {
        var acia = resetACIA(Control.div16_8N1)
        acia.write(1, 0xB4)
        #expect(acia.peek(0) & MC6850.Status.tdre == 0)
        #expect(acia.isBusy)
        let (bits, sent) = acia.transmit(bits: 12)
        // The first bit time takes the byte; then start, data, stop, idle.
        #expect(Array(bits[1...]) == frameBits(0xB4) + [true])
        #expect(sent == [0xB4])
        #expect(acia.peek(0) & MC6850.Status.tdre != 0)
        #expect(!acia.isBusy)
    }

    @Test func transmitsSevenBitsWithParityAndTwoStopBits() {
        var acia = resetACIA(Control.div16_7O2)
        acia.write(1, 0xC1)
        let (bits, sent) = acia.transmit(bits: 13)
        #expect(Array(bits[1...]) == frameBits(0x41, dataBits: 7, parity: .odd, stopBits: 2) + [true])
        #expect(sent == [0x41])
    }

    @Test func tdreGoesHighWhenTheShiftRegisterTakesTheByte() {
        var acia = resetACIA(Control.div16_8N1)
        acia.write(1, 0x01)
        _ = acia.transmit(bits: 1)
        #expect(acia.peek(0) & MC6850.Status.tdre != 0)
        // Double buffered: the next byte waits for the frame to finish.
        acia.write(1, 0x02)
        let (_, sent) = acia.transmit(bits: 20)
        #expect(sent == [0x01, 0x02])
    }

    @Test func transmitIRQFollowsTDREAndCTS() {
        var acia = resetACIA(Control.div16_8N1 | Control.txIRQ)
        #expect(acia.irq)
        #expect(acia.peek(0) & MC6850.Status.irq != 0)
        acia.write(1, 0x55)
        #expect(!acia.irq)
        _ = acia.transmit(bits: 1)
        #expect(acia.irq)
        // High CTS inhibits TDRE, and with it the interrupt.
        acia.setCTS(true)
        #expect(!acia.irq)
        #expect(acia.peek(0) == MC6850.Status.cts)
    }

    @Test func breakHoldsTxDLow() {
        var acia = resetACIA(0x75)
        let (bits, _) = acia.transmit(bits: 3)
        #expect(bits == [true, false, false])
        #expect(acia.rts)
        acia.write(0, 0x55)
        #expect(!acia.rts)
        acia.write(0, 0x15)
        #expect(acia.rts)
    }

    @Test func stateRoundTripsMidFrame() throws {
        var acia = resetACIA()
        let bits = frameBits(0x9E)
        acia.receive(Array(bits[..<4]))
        var copy = try JSONDecoder().decode(MC6850.self, from: JSONEncoder().encode(acia))
        #expect(copy == acia)
        copy.receive(Array(bits[4...]))
        #expect(readData(&copy) == 0x9E)
    }
}

// MARK: UEF

private func u16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func f32(_ value: Float) -> [UInt8] { (0..<4).map { UInt8(value.bitPattern >> ($0 * 8) & 0xFF) } }

/// A gzip member of `bytes` (the deflate stream from the Compression
/// framework).
private func gzip(_ bytes: [UInt8], name: String? = nil) throws -> [UInt8] {
    let deflated = try (Data(bytes) as NSData).compressed(using: .zlib) as Data
    var header: [UInt8] = [0x1F, 0x8B, 8, name == nil ? 0 : 0x08, 0, 0, 0, 0, 0, 3]
    if let name { header += Array(name.utf8) + [0] }
    let crc = Gzip.crc32(bytes)
    let size = UInt32(bytes.count)
    return header + [UInt8](deflated) + (0..<4).map { UInt8(crc >> ($0 * 8) & 0xFF) }
        + (0..<4).map { UInt8(size >> ($0 * 8) & 0xFF) }
}

struct UEFTests {
    @Test func readsChunks() throws {
        let file = UEF.file([.init(id: 0x0000, data: Array("macbeeb\0".utf8)), .init(id: 0x0110, data: u16(1500))])
        #expect(try UEF.chunks(file) == [.init(id: 0x0000, data: Array("macbeeb\0".utf8)),
                                          .init(id: 0x0110, data: u16(1500))])
    }

    @Test func rejectsBadFiles() throws {
        #expect(throws: UEF.Error.notUEF) { try UEF.chunks(Array("Not a UEF file".utf8)) }
        var file = UEF.file([.init(id: 0x0100, data: [1, 2, 3])])
        file.removeLast()
        #expect(throws: UEF.Error.truncated(chunk: 0x0100)) { try UEF.chunks(file) }
    }

    @Test func gunzips() throws {
        let file = UEF.file([.init(id: 0x0100, data: Array(0...255))])
        #expect(try UEF.chunks(gzip(file, name: "test.uef")) == UEF.chunks(file))

        // Members concatenated (as BeebEm writes them).
        let half = file.count / 2
        let twoMembers = try gzip(Array(file[..<half])) + gzip(Array(file[half...]))
        #expect(try UEF.chunks(twoMembers) == UEF.chunks(file))

        var corrupt = try gzip(file)
        corrupt[corrupt.count - 6] ^= 1
        #expect(throws: UEF.Error.badGzip) { try UEF.chunks(corrupt) }
        #expect(throws: UEF.Error.badGzip) { try UEF.chunks(Array(gzip(file).dropLast(12))) }
    }

    @Test func turnsChunksIntoSegments() {
        let segments = UEF.segments([
            .init(id: 0x0000, data: Array("origin\0".utf8)),
            .init(id: 0x0110, data: u16(1500)),
            .init(id: 0x0100, data: [0x2A]),
            .init(id: 0x0111, data: u16(100) + u16(50)),
            .init(id: 0x0112, data: u16(600)),
            .init(id: 0x0116, data: f32(0.5)),
            .init(id: 0x0104, data: [7, UInt8(ascii: "E"), 0xFF, 0x41]),
            .init(id: 0x0102, data: [8 + 3, 0b1100_0101]),
            .init(id: 0x0114, data: [3, 0, 0, UInt8(ascii: "P"), UInt8(ascii: "W"), 0b1010_0000]),
            .init(id: 0x0117, data: u16(300)),
            .init(id: 0x0100, data: [0x01]),
            .init(id: 0x0113, data: f32(1300)),
            .init(id: 0x0110, data: u16(10)),
            .init(id: 0x0115, data: u16(180)),
        ])
        let sevenE1 = Tape.Framing(dataBits: 7, parity: .even, stopBits: 1)
        #expect(segments == [
            .tone(.high, slots: 1500),
            .frames([0x2A]),
            .tone(.high, slots: 100), .frames([0xAA]), .tone(.high, slots: 50),
            .tone(.silence, slots: 600),
            .tone(.silence, slots: 1200),
            .frames([0x41], sevenE1),
            // 5 bits, least significant first: 1 0 1 0 0.
            .pattern([.high, .high, .low, .low, .high, .high, .low, .low, .low, .low]),
            // Cycles 1 0 1.
            .pattern([.high, .low, .low, .high]),
            .frames([0x01], slotsPerBit: 8),
            .tone(.high, slots: 10, rate: 2600),
        ])
        #expect(segments[1].slots == 20)
        #expect(segments[7].slots == 20)
        #expect(segments[10].slots == 80)
    }

    @Test func framesPlayStartDataParityStop() {
        let tape = Tape(segments: [.frames([0x41], Tape.Framing(dataBits: 7, parity: .even, stopBits: 2), slotsPerBit: 1)])
        // Sample the middle of each 1/2400s slot.
        var slots: [Tape.Signal] = []
        var us = 0
        for slot in 0..<12 {
            while us < (2 * slot + 1) * 1_000_000 / 4800 {
                _ = tape.tick()
                us += 1
            }
            slots.append(tape.signal)
        }
        // Start, 1000001 (LSB first), even parity 0, two stops, then the end.
        #expect(slots == [.low, .high, .low, .low, .low, .low, .low, .high, .low, .high, .high, .silence])
        #expect(tape.isAtEnd)
    }

    @Test func tapeKnowsWhereItIs() throws {
        let tape = Tape(segments: [.tone(.high, slots: 2400), .tone(.silence, slots: 1200, rate: 1200)])
        #expect(tape.duration == 2)
        for _ in 0..<1_500_000 { _ = tape.tick() }
        #expect(abs(tape.elapsed - 1.5) < 1e-6)
        #expect(tape.signal == .silence)
        let saved = tape.state
        let copy = Tape(state: try PropertyListDecoder().decode(Tape.State.self, from: PropertyListEncoder().encode(saved)))
        #expect(copy.state == saved)
        #expect(abs(copy.elapsed - 1.5) < 1e-6)
        tape.rewind()
        #expect(tape.elapsed == 0)
        #expect(tape.signal == .high)
    }

    @Test func readsBeebEmsTestTape() throws {
        // Pugwash, a BASIC program: BeebEm's test tape, its gzip members
        // as BeebEm writes them.
        let chunks = try UEF.chunks(testResource("tapes/pugwash.uef"))
        #expect(chunks.first?.id == 0x0000)
        #expect(chunks.filter { $0.id == 0x0100 }.map(\.data.count) == [1, 1, 288, 288, 288, 288, 288, 70])
        let blocks = chunks.filter { $0.id == 0x0100 && $0.data.count > 1 }.map(\.data)
        #expect(blocks.allSatisfy { $0.starts(with: [0x2A] + Array("PUGWASH".utf8) + [0]) })
    }
}

// MARK: Cassette

/// A serial ULA and ACIA with the OS's cassette IRQ handler: read the status,
/// then the data.
private struct CassetteHost {
    struct Event: Equatable {
        var us: Int
        var status: UInt8
        var data: UInt8
        var dcd: Bool { status & MC6850.Status.dcd != 0 }
        var rdrf: Bool { status & MC6850.Status.rdrf != 0 }
    }

    var ula = SerialULA()
    var tape: Tape?
    var us = 0
    var events: [Event] = []

    /// The OS's cassette read setup (&FB50): motor on, cassette, ACIA /16
    /// (or /64 at 300 baud), 8N1, RX IRQ.
    init(_ tape: Tape?, aciaControl: UInt8 = 0xD5) {
        self.tape = tape
        ula.writeACIA(0, Control.masterReset)
        ula.writeControl(0x85)
        ula.writeACIA(0, aciaControl)
    }

    mutating func run(us count: Int) {
        for _ in 0..<count {
            ula.update(tape: tape)
            us += 1
            if ula.irq {
                let status = ula.readACIA(0)
                events.append(Event(us: us, status: status, data: ula.readACIA(1)))
            }
        }
    }

    var bytes: [UInt8] { events.filter { $0.rdrf && !$0.dcd }.map(\.data) }
}

struct CassetteTests {
    static let carrierDetectUs = 174_000

    @Test func powersUpLikeTheOldStub() {
        var ula = SerialULA()
        #expect(ula.peekACIA(0) == MC6850.Status.tdre)
        ula.writeACIA(0, Control.masterReset)
        #expect(ula.peekACIA(0) == 0)
        // RS423 with nothing connected: CTS high inhibits TDRE.
        ula.writeControl(0x40)
        #expect(ula.peekACIA(0) == MC6850.Status.cts)
        ula.writeACIA(0, 0x56)
        #expect(ula.peekACIA(0) == MC6850.Status.cts)
        ula.writeControl(0x00)
        #expect(ula.peekACIA(0) == MC6850.Status.tdre)
    }

    @Test func reportsTheMotorRelay() {
        var ula = SerialULA()
        let switches = [0x85, 0x85, 0xC5, 0x05].map { ula.writeControl($0) }
        #expect(switches == [true, false, false, true])
        #expect(!ula.motorOn)
    }

    @Test func carrierRaisesDCDFor210us() {
        var host = CassetteHost(Tape(segments: [.tone(.high, slots: 2400)]), aciaControl: 0x55)
        host.run(us: Self.carrierDetectUs - 1)
        #expect(host.ula.peekACIA(0) & MC6850.Status.dcd == 0)
        host.run(us: 1)
        #expect(host.ula.acia.dcd)
        host.run(us: 209)
        #expect(host.ula.acia.dcd)
        host.run(us: 1)
        #expect(!host.ula.acia.dcd)
        // Latched (no RIE here, so nothing has read it).
        #expect(host.ula.peekACIA(0) & MC6850.Status.dcd != 0)
        // Once only, however long the carrier goes on.
        _ = host.ula.readACIA(1)
        host.run(us: 500_000)
        #expect(host.ula.peekACIA(0) & MC6850.Status.dcd == 0)
    }

    @Test func shortCarrierRaisesNoDCD() {
        var host = CassetteHost(Tape(segments: [.tone(.high, slots: 400), .frames([0xAA]), .tone(.high, slots: 400)]))
        host.run(us: 500_000)
        #expect(host.events.map(\.data) == [0xAA])
        #expect(!host.events[0].dcd)
    }

    @Test func readsABlockAsTheOSDoes() {
        let block: [UInt8] = [0x2A] + Array("HELLO".utf8) + [0, 0x00, 0x19, 0xFF, 0xFF, 0x23, 0x80, 0xFF, 0xFF, 0xFF, 0x55]
        let tape = Tape(segments: [.tone(.silence, slots: 240), .tone(.high, slots: 600), .frames(block),
                                   .tone(.high, slots: 100)])
        var host = CassetteHost(tape)
        host.run(us: 1_000_000)

        // First the carrier (DCD, nothing received), then each byte with DCD
        // clear, one per 10 bit times at 1200 baud.
        let carrierStart = 100_000
        #expect(host.events.first?.dcd == true)
        #expect(host.events.first?.rdrf == false)
        let dcdAt = host.events[0].us - carrierStart
        #expect(abs(dcdAt - Self.carrierDetectUs) < 10)
        #expect(Array(host.events.dropFirst()).allSatisfy { $0.rdrf && !$0.dcd })
        #expect(host.bytes == block)
        let gaps = zip(host.events.dropFirst(2), host.events.dropFirst()).map { $0.us - $1.us }
        // 160 ACIA clocks (8320us), now and then one more to catch up.
        #expect(gaps.allSatisfy { $0 == 8320 || $0 == 8372 }, "\(gaps)")
        #expect(abs(Double(gaps.reduce(0, +)) / Double(gaps.count) - 8333) < 5)
        // The first byte lands at the middle of its first stop bit.
        let blockStart = carrierStart + 250_000
        #expect(abs(host.events[1].us - blockStart - 9 * 833 - 416) < 30)
        #expect(host.events.allSatisfy { $0.status & (MC6850.Status.fe | MC6850.Status.ovrn | MC6850.Status.pe) == 0 })
    }

    @Test func dummyByteThenCarrierAgain() {
        // &0111 as at the start of a file: DCD, the dummy &AA, DCD again.
        let tape = Tape(segments: UEF.segments([.init(id: 0x0111, data: u16(1200) + u16(600)),
                                                .init(id: 0x0100, data: [0x2A])]))
        var host = CassetteHost(tape)
        host.run(us: 1_200_000)
        #expect(host.events.map(\.dcd) == [true, false, true, false])
        #expect(host.events.map(\.data).suffix(1) == [0x2A])
        #expect(host.events[1].data == 0xAA)
    }

    @Test func readsAt300Baud() {
        let tape = Tape(segments: UEF.segments([.init(id: 0x0117, data: u16(300)), .init(id: 0x0110, data: u16(600)),
                                                .init(id: 0x0100, data: [0x2A, 0x12, 0xEF])]))
        var host = CassetteHost(tape, aciaControl: 0xD6)
        host.run(us: 400_000)
        #expect(host.bytes == [0x2A, 0x12, 0xEF])
    }

    @Test func playsBeebEmsTestTape() throws {
        let tape = try Tape(image: testResource("tapes/pugwash.uef"))
        var host = CassetteHost(tape)
        // The first block: after the leader, the dummy byte and more carrier.
        host.run(us: 8_500_000)
        let bytes = host.bytes
        #expect(bytes.first == 0xAA)
        let header = Array(bytes.drop { $0 != 0x2A }.prefix(9))
        #expect(header == [0x2A] + Array("PUGWASH".utf8) + [0])
        // Then the whole block, CRC and all.
        let chunks = try UEF.chunks(testResource("tapes/pugwash.uef"))
        let firstBlock = chunks.first { $0.id == 0x0100 && $0.data.count > 1 }!.data
        #expect(Array(bytes.drop { $0 != 0x2A }.prefix(firstBlock.count)) == firstBlock)
    }

    @Test func motorOffStopsTheTape() {
        let tape = Tape(segments: [.tone(.high, slots: 2400)])
        var host = CassetteHost(tape)
        host.run(us: 100_000)
        host.ula.writeControl(0x05)
        let elapsed = tape.elapsed
        host.run(us: 300_000)
        #expect(tape.elapsed == elapsed)
        #expect(host.events.isEmpty)
        // Carrier has to be unbroken for its whole 174ms.
        host.ula.writeControl(0x85)
        host.run(us: Self.carrierDetectUs - 1)
        #expect(host.events.isEmpty)
        host.run(us: 1)
        #expect(host.events.count == 1)
    }

    @Test func noTapeIsSilence() {
        var host = CassetteHost(nil)
        host.run(us: 300_000)
        #expect(host.events.isEmpty)
        #expect(host.ula.peekACIA(0) == MC6850.Status.tdre)
    }

    @Test func writesAt1200Baud() {
        // The OS's write setup (&FBE2): motor on, ACIA reset, /16 8N1.
        var ula = SerialULA()
        ula.writeControl(0x85)
        ula.writeACIA(0, Control.masterReset)
        ula.writeACIA(0, 0x15)
        ula.writeACIA(1, 0xAA)
        var sentAt: [Int] = []
        for us in 1...20_000 {
            if ula.peekACIA(0) & MC6850.Status.tdre != 0 && sentAt.count == ula.transmitCount && us > 1 {
                ula.writeACIA(1, UInt8(us & 0xFF))
            }
            let before = ula.transmitCount
            ula.update(tape: nil)
            if ula.transmitCount != before { sentAt.append(us) }
        }
        #expect(ula.transmitCount == 2)
        #expect(sentAt.count == 2)
        #expect(abs(sentAt[1] - sentAt[0] - 8320) < 10, "\(sentAt)")
    }

    @Test func rs423TransmitsAtTheSelectedRate() {
        var ula = SerialULA()
        // 9600 baud both ways (rate 4), ACIA /64 8N1.
        ula.writeControl(0x40 | 0x24)
        ula.writeACIA(0, Control.masterReset)
        ula.writeACIA(0, 0x56)
        ula.writeACIA(1, 0x41)
        var us = 0
        while ula.transmitCount == 0 && us < 100_000 {
            ula.update(tape: nil)
            us += 1
        }
        #expect(ula.lastTransmitted == 0x41)
        // A bit time to take the byte, then ten bits, at 9615 baud.
        #expect(abs(us - 11 * 104) < 110, "\(us)")
    }

    @Test func idlesWhenNothingIsHappening() {
        var ula = SerialULA()
        ula.writeACIA(0, Control.masterReset)
        ula.writeACIA(0, 0x56)
        let before = ula
        for _ in 0..<10_000 { ula.update(tape: nil) }
        #expect(ula == before)
    }

    @Test func stateRoundTripsMidBlock() throws {
        let block = Array(0..<64).map { UInt8($0 * 7 & 0xFF) }
        let segments: [Tape.Segment] = [.tone(.high, slots: 600), .frames(block), .tone(.high, slots: 100)]
        var host = CassetteHost(Tape(segments: segments))
        host.run(us: 300_000)

        let ulaData = try PropertyListEncoder().encode(host.ula)
        let tapeData = try PropertyListEncoder().encode(host.tape!.state)
        var copy = host
        copy.ula = try PropertyListDecoder().decode(SerialULA.self, from: ulaData)
        copy.tape = Tape(state: try PropertyListDecoder().decode(Tape.State.self, from: tapeData))
        #expect(copy.ula == host.ula)

        host.run(us: 600_000)
        copy.run(us: 600_000)
        #expect(copy.events == host.events)
        #expect(host.bytes == block)
    }
}

// MARK: CSW

/// The pulses (half waves, in samples at 44.1kHz) for `signals`, a slot each.
private func pulses(_ signals: [Tape.Signal]) -> [Int] {
    var result: [Int] = []
    var time = 0.0, last = 0.0
    func edge() {
        let samples = Int((time - last).rounded())
        result.append(samples)
        last += Double(samples)
    }
    let slot = 44100.0 / 2400
    var i = 0
    while i < signals.count {
        switch signals[i] {
        case .high:
            time += slot / 2; edge()
            time += slot / 2; edge()
        case .low:
            time += slot; edge()
        case .silence:
            time += slot
            if i + 1 == signals.count || signals[i + 1] != .silence { edge() }
        }
        i += 1
    }
    return result
}

private func rle(_ pulses: [Int]) -> [UInt8] {
    pulses.flatMap { pulse in pulse < 256 ? [UInt8(pulse)] : [0] + (0..<4).map { UInt8(pulse >> ($0 * 8) & 0xFF) } }
}

struct CSWTests {
    static func signals(_ segments: [Tape.Segment]) -> [Tape.Signal] {
        segments.flatMap { segment in (0..<segment.slots).map { segment.signal(at: $0) } }
    }

    static let segments: [Tape.Segment] = [.tone(.silence, slots: 100), .tone(.high, slots: 600),
                                           .frames([0x2A, 0x00, 0xFF, 0x5A]), .tone(.high, slots: 50)]

    @Test func readsVersion1() throws {
        let header = Array("Compressed Square Wave\u{1A}".utf8) + [1, 1] + u16(44100) + [1, 0, 0, 0, 0]
        let file = header + rle(pulses(Self.signals(Self.segments)))
        let tape = try Tape(image: file)
        // Silence at the start, then the same slots.
        #expect(Self.signals(tape.segments).drop { $0 == .silence }.elementsEqual(Self.signals(Array(Self.segments.dropFirst()))))
    }

    @Test func readsVersion2ZRLE() throws {
        let data = rle(pulses(Self.signals(Self.segments)))
        let deflated = try [UInt8]((Data(data) as NSData).compressed(using: .zlib) as Data)
        var header = Array("Compressed Square Wave\u{1A}".utf8) + [2, 0]
        header += u16(44100) + u16(0) + [0, 0, 0, 0] + [2, 0, 0] + [UInt8](repeating: 0, count: 16)
        let file = header + [0x78, 0x9C] + deflated + [0, 0, 0, 0]
        let tape = try CSW.tape(file)
        var host = CassetteHost(tape)
        host.run(us: 600_000)
        #expect(host.bytes == [0x2A, 0x00, 0xFF, 0x5A])
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: CSW.Error.notCSW) { try CSW.tape(Array("Compressed Square Wave".utf8)) }
    }
}


// MARK: Swift decompressors (for builds without the Compression framework)

struct DecompressorTests {
    /// Text-like, repetitive and incompressible data, in sizes that make
    /// stored, fixed and dynamic deflate blocks, and several LZ4 blocks.
    static let samples: [[UInt8]] = {
        var seed: UInt32 = 0x1234_5678
        func next() -> UInt8 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: seed >> 24)
        }
        let text = Array(String(repeating: "10 PRINT \"HELLO WORLD\": GOTO 10\n", count: 400).utf8)
        return [[], [42], Array(repeating: 0xE5, count: 70_000), text, (0..<200_000).map { _ in next() },
                text + (0..<5000).map { _ in next() } + text]
    }()

    @Test func inflatesWhatFoundationDeflates() throws {
        for sample in Self.samples {
            let deflated = try [UInt8]((Data(sample) as NSData).compressed(using: .zlib) as Data)
            let result = try #require(Inflate.inflate(deflated[...] + [1, 2, 3]))
            #expect(result.data == sample && result.used == deflated.count)
            #expect(Inflate.inflate(deflated.dropLast()) == nil || sample.isEmpty)
        }
    }

    /// BeebCore's own LZ4 (Linux's, for snapshots of the Master 512's
    /// RAM) makes Apple's container, which its decoder reads back.
    @Test func encodesLZ4() throws {
        for sample in Self.samples {
            let compressed = LZ4.compress(Data(sample))
            #expect(LZ4.decompress(compressed) == Data(sample))
            if sample.count > 1000 && sample.first == sample.last {
                #expect(compressed.count < sample.count, "\(sample.count) bytes")
            }
        }
        // A megabyte of RAM that's mostly empty, as a Master 512's is.
        var ram = [UInt8](repeating: 0, count: 1 << 20)
        for i in stride(from: 0, to: ram.count, by: 4096) { ram[i] = UInt8(truncatingIfNeeded: i >> 12) }
        let compressed = LZ4.compress(Data(ram))
        #expect(compressed.count < 100_000)
        #expect(LZ4.decompress(compressed) == Data(ram))
    }

    // (The Compression framework's LZ4 is only on the Mac.)
    @Test(.enabled(if: canImportDarwin))
    func decodesAppleLZ4() throws {
        for sample in Self.samples {
            let compressed = try (Data(sample) as NSData).compressed(using: .lz4) as Data
            #expect(LZ4.decompress(compressed) == Data(sample))
            #expect(LZ4.decompress(compressed.dropLast(5)) == nil)
        }
    }
}

#if canImport(Darwin)
private let canImportDarwin = true
#else
private let canImportDarwin = false
#endif
