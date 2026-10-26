// A cassette: what the tape head plays, as a sequence of segments (carrier
// tone, framed bytes, gaps), and where the tape is.
//
// Time on the tape is counted in slots, each half a cycle of the base
// frequency's low tone: 1/2400s normally. A slot holds one cycle of high
// tone (2400Hz), half a cycle of low tone (1200Hz) or silence, so a bit at
// 1200 baud is two slots (0: one cycle of 1200Hz, 1: two of 2400Hz) and at
// 300 baud eight. That's the resolution the serial ULA's tone decoder needs.
//
// The serial ULA calls `tick()` once per 1MHz cycle while the motor is on,
// and reads `signal`.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public final class Tape {
    /// What's under the head.
    public enum Signal: UInt8, Codable, Sendable {
        case silence
        /// 1200Hz (at the standard base frequency): a 0.
        case low
        /// 2400Hz: a 1, or carrier.
        case high
    }

    /// How bytes are framed: a start bit (0), the data bits from the least
    /// significant, an optional parity bit, then stop bits (1).
    public struct Framing: Codable, Sendable, Equatable {
        public enum Parity: UInt8, Codable, Sendable { case none, even, odd }

        public var dataBits: Int
        public var parity: Parity
        public var stopBits: Int

        /// The Acorn filing system's 8N1.
        public static let acorn = Framing(dataBits: 8, parity: .none, stopBits: 1)

        public init(dataBits: Int, parity: Parity, stopBits: Int) {
            precondition((1...8).contains(dataBits) && (0...8).contains(stopBits), "Bad framing")
            self.dataBits = dataBits
            self.parity = parity
            self.stopBits = stopBits
        }

        var bitsPerFrame: Int { 1 + dataBits + (parity == .none ? 0 : 1) + stopBits }
    }

    public struct Segment: Sendable, Equatable {
        public enum Content: Sendable, Equatable {
            /// Constant: carrier (`.high`) or a gap (`.silence`).
            case tone(Signal)
            /// Bytes, each framed, each bit `slotsPerBit` slots of one tone.
            case frames([UInt8], Framing, slotsPerBit: Int)
            /// Slot by slot.
            case pattern([Signal])
        }

        public var content: Content
        /// Length in slots.
        public private(set) var slots: Int
        /// Slots per second: twice the base frequency, normally 2400.
        public var rate: Int

        public static let standardRate = 2400

        public static func tone(_ signal: Signal, slots: Int, rate: Int = standardRate) -> Segment {
            Segment(content: .tone(signal), slots: max(slots, 0), rate: rate)
        }

        /// Bytes at 1200 baud (`slotsPerBit` 2) or 300 (8).
        public static func frames(_ bytes: [UInt8], _ framing: Framing = .acorn, slotsPerBit: Int = 2,
                                  rate: Int = standardRate) -> Segment {
            precondition(slotsPerBit > 0)
            return Segment(content: .frames(bytes, framing, slotsPerBit: slotsPerBit),
                           slots: bytes.count * framing.bitsPerFrame * slotsPerBit, rate: rate)
        }

        public static func pattern(_ signals: [Signal], rate: Int = standardRate) -> Segment {
            Segment(content: .pattern(signals), slots: signals.count, rate: rate)
        }

        private init(content: Content, slots: Int, rate: Int) {
            precondition(rate > 0, "Bad tape rate")
            self.content = content
            self.slots = slots
            self.rate = rate
        }

        func signal(at slot: Int) -> Signal {
            switch content {
            case .tone(let signal):
                return signal
            case .pattern(let signals):
                return signals[slot]
            case .frames(let bytes, let framing, let slotsPerBit):
                let bit = slot / slotsPerBit
                let frameBits = framing.bitsPerFrame
                let byte = Int(bytes[bit / frameBits]) & (1 << framing.dataBits - 1)
                let index = bit % frameBits
                if index == 0 {
                    return .low
                }
                if index <= framing.dataBits {
                    return byte >> (index - 1) & 1 != 0 ? .high : .low
                }
                if index == framing.dataBits + 1 && framing.parity != .none {
                    let odd = byte.nonzeroBitCount & 1 != 0
                    return odd != (framing.parity == .odd) ? .high : .low
                }
                return .high
            }
        }
    }

    public private(set) var segments: [Segment]

    // Position.
    private var segmentIndex = 0
    private var slot = 0
    /// Toward the next slot: `rate` per microsecond, a slot every million.
    private var phase = 0
    /// The current segment's rate; 0 at the end of the tape.
    private var rate = 0
    public private(set) var signal = Signal.silence

    public init(segments: [Segment]) {
        self.segments = segments.filter { $0.slots > 0 }
        rewind()
    }

    public var isAtEnd: Bool { segmentIndex == segments.count }

    public func rewind() {
        segmentIndex = 0
        slot = 0
        phase = 0
        enterSegment()
    }

    /// Seconds from the start of the tape to its end, and to the head.
    public var duration: Double {
        segments.reduce(0) { $0 + Double($1.slots) / Double($1.rate) }
    }

    public var elapsed: Double {
        let before = segments[..<segmentIndex].reduce(0) { $0 + Double($1.slots) / Double($1.rate) }
        guard !isAtEnd else { return before }
        let rate = Double(segments[segmentIndex].rate)
        return before + (Double(slot) + Double(phase) / 1_000_000) / rate
    }

    /// Moves the tape on a microsecond; true when `signal` has changed.
    @inline(__always)
    public func tick() -> Bool {
        phase &+= rate
        guard phase >= 1_000_000 else { return false }
        phase -= 1_000_000
        return nextSlot()
    }

    private func nextSlot() -> Bool {
        let old = signal
        slot += 1
        if slot == segments[segmentIndex].slots {
            slot = 0
            segmentIndex += 1
            enterSegment()
        } else {
            signal = segments[segmentIndex].signal(at: slot)
        }
        return signal != old
    }

    private func enterSegment() {
        if isAtEnd {
            rate = 0
            signal = .silence
        } else {
            rate = segments[segmentIndex].rate
            signal = segments[segmentIndex].signal(at: slot)
        }
    }

    // MARK: State

    /// The tape's contents and position.
    public struct State: Codable, Sendable, Equatable {
        fileprivate var segments: [Segment]
        fileprivate var segmentIndex: Int
        fileprivate var slot: Int
        fileprivate var phase: Int
    }

    public var state: State {
        State(segments: segments, segmentIndex: segmentIndex, slot: slot, phase: phase)
    }

    public convenience init(state: State) {
        self.init(segments: [])
        restore(state)
    }

    public func restore(_ state: State) {
        segments = state.segments.filter { $0.slots > 0 }
        segmentIndex = min(max(state.segmentIndex, 0), segments.count)
        slot = isAtEnd ? 0 : min(max(state.slot, 0), segments[segmentIndex].slots - 1)
        phase = min(max(state.phase, 0), 999_999)
        enterSegment()
    }
}

/// Bytes and patterns encode as data, not arrays of numbers.
extension Tape.Segment: Codable {
    private enum CodingKeys: String, CodingKey { case tone, bytes, framing, slotsPerBit, pattern, slots, rate }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rate, forKey: .rate)
        switch content {
        case .tone(let signal):
            try c.encode(signal, forKey: .tone)
            try c.encode(slots, forKey: .slots)
        case .frames(let bytes, let framing, let slotsPerBit):
            try c.encode(Data(bytes), forKey: .bytes)
            try c.encode(framing, forKey: .framing)
            try c.encode(slotsPerBit, forKey: .slotsPerBit)
        case .pattern(let signals):
            try c.encode(Data(signals.map(\.rawValue)), forKey: .pattern)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rate = try c.decode(Int.self, forKey: .rate)
        guard rate > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .rate, in: c, debugDescription: "Bad tape rate")
        }
        if let signal = try c.decodeIfPresent(Tape.Signal.self, forKey: .tone) {
            self = .tone(signal, slots: try c.decode(Int.self, forKey: .slots), rate: rate)
        } else if let bytes = try c.decodeIfPresent(Data.self, forKey: .bytes) {
            let framing = try c.decode(Tape.Framing.self, forKey: .framing)
            let slotsPerBit = try c.decode(Int.self, forKey: .slotsPerBit)
            guard (1...8).contains(framing.dataBits), (0...8).contains(framing.stopBits), slotsPerBit > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .framing, in: c, debugDescription: "Bad framing")
            }
            self = .frames([UInt8](bytes), framing, slotsPerBit: slotsPerBit, rate: rate)
        } else {
            let raw = try c.decode(Data.self, forKey: .pattern)
            let signals = try raw.map { byte in
                guard let signal = Tape.Signal(rawValue: byte) else {
                    throw DecodingError.dataCorruptedError(forKey: .pattern, in: c, debugDescription: "Bad signal")
                }
                return signal
            }
            self = .pattern(signals, rate: rate)
        }
    }
}
