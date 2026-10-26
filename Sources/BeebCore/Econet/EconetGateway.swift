// An Internet gateway: a device on the local line that stands in for the
// stations on other Macs, so the BBCs here can talk to them with their own
// network software, unchanged.
//
// Econet's four-way handshake (scout, acknowledgement, data,
// acknowledgement) wants each frame answered within about 15 bit-times,
// far less than a trip across the Internet. So no frame is answered for
// the far station from here. Instead, when a local BBC sends a frame to a
// remote station, the gateway holds the line with flags (as a bridge does:
// a busy line isn't an idle one, so the sender keeps waiting) and sends
// the frame to the far gateway. That one puts it on its own line, as if
// from the sender, and sends back whatever the real station answers: its
// next frame, or nothing (it went quiet: it isn't listening, or the
// transaction's over). Only then does this gateway stop the flags and put
// the answer on the line here. Every frame crosses once, each line is held
// while it's in flight, and a sender only ever sees an acknowledgement its
// real destination sent.
//
// The frames alternate between the two stations, as Acorn's NFS sends them:
// scout, acknowledgement, data, acknowledgement; or for the immediate
// operations PEEK and machine type, scout and the answer carrying the data,
// and for HALT and CONTINUE, scout and acknowledgement. The scout says
// which, so the last frame isn't held for an answer that won't come.
//
// Broadcasts go to every other gateway and onto their lines; nobody
// answers them.
//
// One transaction at a time per gateway: a line held for one can't carry
// another. A frame that starts a transaction while the gateway's busy is
// refused (its sender sees "not listening", and NFS tries again), which
// also keeps two gateways each holding their line for the other from
// waiting on each other.

/// What gateways send each other, through the room.
public enum EconetGatewayMessage: Sendable, Equatable {
    /// A frame of a transaction, as it was on the line (addresses first;
    /// no flags or check bytes). `stage` counts the transaction's frames
    /// from the scout (0); a final one (the data's acknowledgement)
    /// expects no answer.
    case frame(transaction: UInt32, stage: Int, final: Bool, bytes: [UInt8])
    /// The station the last frame went to didn't answer it (from: that
    /// station, to: the one whose frame it was).
    case noReply(transaction: UInt32, from: UInt8, to: UInt8)
    /// A frame to station 255.
    case broadcast(bytes: [UInt8])

    /// The stations it's from and for, as the room routes it (255:
    /// everyone).
    public var route: (from: UInt8, to: UInt8) {
        switch self {
        case .frame(_, _, _, let bytes), .broadcast(let bytes):
            (bytes.count > 2 ? bytes[2] : 0, bytes.count > 0 ? bytes[0] : 0)
        case .noReply(_, let from, let to):
            (from, to)
        }
    }
}

/// (Sendable: what's shared with other threads is under its lock; the rest
/// is only used on the network's thread.)
public final class EconetGateway: EconetLineDevice, @unchecked Sendable {
    /// Stations on other Macs, which this gateway answers for.
    public var remoteStations: Set<UInt8> {
        get { lock.withLock { _remoteStations } }
        set { lock.withLock { _remoteStations = newValue } }
    }
    /// The local stations shared into the room, or nil for all. Frames from
    /// the room for others are refused, and theirs aren't sent.
    public var sharedStations: Set<UInt8>? {
        get { lock.withLock { _sharedStations } }
        set { lock.withLock { _sharedStations = newValue } }
    }
    /// What the gateway sends to the room (called on the network's thread).
    public var send: (EconetGatewayMessage) -> Void
    /// How long the line's held for an answer before giving up, in cycles
    /// (2 seconds).
    public var holdLimit: UInt64 = 4_000_000
    /// How long a frame from the room waits for the line to be free.
    public var lineWaitLimit: UInt64 = 200_000

    /// What it's doing, for the inspector and tests.
    public enum Activity: Sendable, Equatable {
        case idle
        /// Holding the line for a remote station's answer.
        case holding(station: UInt8)
        /// Waiting for a local station to answer a frame from the room.
        case awaitingLocal(station: UInt8)
    }

    public struct Counters: Sendable, Equatable {
        public var framesOut = 0
        public var framesIn = 0
        public var broadcastsOut = 0
        public var broadcastsIn = 0
        public var noReplies = 0
        public var refusedBusy = 0
        public var timeouts = 0
    }

    public var activity: Activity { lock.withLock { publishedActivity } }
    public var counters: Counters { lock.withLock { publishedCounters } }

    public init(send: @escaping (EconetGatewayMessage) -> Void = { _ in }) {
        self.send = send
    }

    /// A message from the room, for the network's thread to act on.
    public func receive(_ message: EconetGatewayMessage) {
        lock.withLock { inbox.append(message) }
    }

    // MARK: State (the network's thread)

    private let lock = NSLock()
    private var _remoteStations: Set<UInt8> = []
    private var _sharedStations: Set<UInt8>?
    private var inbox: [EconetGatewayMessage] = []
    private var publishedActivity = Activity.idle
    private var publishedCounters = Counters()
    private var counters_ = Counters()

    private struct Transaction {
        /// The local station and the remote one.
        var local: UInt8
        var remote: UInt8
        var id: UInt32
        /// The stage of the last frame either way.
        var stage: Int
        /// The stage of its last frame (from its scout).
        var finalStage: Int

        /// Two frames for PEEK, HALT, CONTINUE and machine type (immediate
        /// operations on port 0); four for everything else.
        static func finalStage(scout bytes: [UInt8]) -> Int {
            guard bytes.count >= 6, bytes[5] == 0 else { return 3 }
            return [0x81, 0x86, 0x87, 0x88].contains(bytes[4] | 0x80) ? 1 : 3
        }
    }

    private enum State {
        case idle
        /// Flags on the line until the room answers (or `deadline`).
        case holding(Transaction, deadline: UInt64)
        /// Sent a frame here for `transaction.remote`; waiting for the local
        /// station's answer, or the line to go quiet after `since`.
        case awaitingLocal(Transaction, since: UInt64)
    }

    private var state = State.idle
    /// `sharedStations`, as of this quantum.
    private var shared: Set<UInt8>?
    private var nextTransaction: UInt32 = 1
    /// Heard symbols still to come, in time order.
    private var heard: [(time: UInt64, symbol: EconetSymbol)] = []
    /// The frame being received, and whether it's spoiled.
    private var receiving: [UInt8] = []
    private var receivingChecks = 0
    private var receivingSpoiled = false
    /// When the line was last busy: the end of the last symbol heard, or of
    /// the gateway's own.
    private var lineQuietSince: UInt64 = 0
    /// What to transmit next (as which station), one symbol a byte-time.
    private var outgoing: [(station: UInt8, symbol: EconetSymbol)] = []
    /// When the gateway's next symbol may start.
    private var transmitAt: UInt64 = 0
    /// The station flags are sent as while holding.
    private var holdingFor: UInt8 = 0
    /// Frames from the room waiting for the line (and since when).
    private var waiting: [(message: EconetGatewayMessage, since: UInt64)] = []

    public func hear(_ symbols: [(time: UInt64, symbol: EconetSymbol)]) {
        heard.append(contentsOf: symbols)
        heard.sort { $0.time < $1.time }
    }

    public func run(from start: UInt64, to end: UInt64, clock: Bool, bitTime: Int) -> [(time: UInt64, station: UInt8, symbol: EconetSymbol)] {
        let byteTime = UInt64(bitTime * 8)
        let quiet = UInt64(bitTime * 15)
        var out: [(time: UInt64, station: UInt8, symbol: EconetSymbol)] = []
        let messages = lock.withLock { () -> [EconetGatewayMessage] in
            defer { inbox.removeAll() }
            return inbox
        }
        let remotes = remoteStations
        shared = sharedStations

        // What's been heard up to the end of this quantum, in order.
        var index = 0
        while index < heard.count && heard[index].time <= end {
            let (time, symbol) = heard[index]
            index += 1
            lineQuietSince = max(lineQuietSince, time)
            hearSymbol(symbol, at: time, remotes: remotes)
        }
        heard.removeFirst(index)

        for message in messages {
            fromRoom(message, at: start, remotes: remotes)
        }
        // Frames from the room waiting for the line: go if it's quiet.
        if case .idle = state, !waiting.isEmpty, outgoing.isEmpty {
            let lineIdle = start >= lineQuietSince + quiet
            let (message, since) = waiting[0]
            if lineIdle && clock {
                waiting.removeFirst()
                transmitFromRoom(message, at: start)
            } else if start > since + lineWaitLimit {
                waiting.removeFirst()
                refuse(message)
            }
        }

        switch state {
        case .idle:
            break
        case .holding(let transaction, let deadline):
            if start >= deadline {
                // No answer: let the line go, so the sender sees it quiet.
                counters_.timeouts += 1
                state = .idle
                outgoing.removeAll()
                _ = transaction
            }
        case .awaitingLocal(let transaction, let since):
            // The local station had its chance: quiet for 15 bits after the
            // gateway's frame, allowing the line's delay both ways and a
            // byte-time more (a symbol's only heard when its last bit's in,
            // but the line was busy from its first: a slow station, like a
            // Level 2 server, holds it with flags before it answers).
            if outgoing.isEmpty && since != .max && start >= max(since, lineQuietSince) + quiet + 64 + byteTime {
                if receiving.isEmpty {
                    counters_.noReplies += 1
                    send(.noReply(transaction: transaction.id, from: transaction.local, to: transaction.remote))
                    state = .idle
                }
            }
        }

        // Transmit: the queued frame, else flags while holding.
        var time = max(transmitAt, start)
        while time < end && clock {
            if !outgoing.isEmpty {
                let next = outgoing.removeFirst()
                out.append((time, next.station, next.symbol))
            } else if case .holding = state {
                out.append((time, holdingFor, .flag))
            } else {
                break
            }
            lineQuietSince = max(lineQuietSince, time + byteTime)
            if case .awaitingLocal(let transaction, _) = state, outgoing.isEmpty {
                // The frame's gone: the answer's due from now.
                state = .awaitingLocal(transaction, since: time + byteTime)
            }
            time += byteTime
        }
        transmitAt = time
        publish()
        return out
    }

    // MARK: The line

    private func hearSymbol(_ symbol: EconetSymbol, at time: UInt64, remotes: Set<UInt8>) {
        switch symbol {
        case .flag:
            if !receiving.isEmpty {
                if !receivingSpoiled && receivingChecks >= 2 && receiving.count >= 4 {
                    heardFrame(receiving, at: time, remotes: remotes)
                }
                receiving.removeAll()
            }
            receivingChecks = 0
            receivingSpoiled = false
        case .byte(let byte):
            receiving.append(byte)
        case .check:
            receivingChecks += 1
        case .abort, .garbage:
            receiving.removeAll()
            receivingChecks = 0
            receivingSpoiled = true
        }
    }

    /// A whole frame from a local station.
    private func heardFrame(_ bytes: [UInt8], at time: UInt64, remotes: Set<UInt8>) {
        let to = bytes[0], from = bytes[2]
        guard !remotes.contains(from), shared?.contains(from) ?? true else { return }
        if to == 0xFF {
            counters_.broadcastsOut += 1
            send(.broadcast(bytes: bytes))
            return
        }
        switch state {
        case .awaitingLocal(var transaction, _) where to == transaction.remote && from == transaction.local:
            // The local station's answer.
            transaction.stage += 1
            let final = transaction.stage >= transaction.finalStage
            counters_.framesOut += 1
            send(.frame(transaction: transaction.id, stage: transaction.stage, final: final, bytes: bytes))
            if final {
                state = .idle
            } else {
                hold(transaction, at: time)
            }
        case .idle where remotes.contains(to) && bytes.count >= 6:
            // A scout for a remote station: a new transaction.
            let transaction = Transaction(local: from, remote: to, id: nextTransaction, stage: 0,
                                          finalStage: Transaction.finalStage(scout: bytes))
            nextTransaction &+= 1
            counters_.framesOut += 1
            send(.frame(transaction: transaction.id, stage: 0, final: false, bytes: bytes))
            hold(transaction, at: time)
        default:
            break
        }
    }

    private func hold(_ transaction: Transaction, at time: UInt64) {
        holdingFor = transaction.remote
        state = .holding(transaction, deadline: time + holdLimit)
        transmitAt = max(transmitAt, time)
    }

    // MARK: The room

    private func fromRoom(_ message: EconetGatewayMessage, at time: UInt64, remotes: Set<UInt8>) {
        switch message {
        case .broadcast:
            counters_.broadcastsIn += 1
            waiting.append((message, time))
        case .noReply(let id, _, let to):
            if case .holding(let transaction, _) = state, transaction.id == id, transaction.local == to {
                // Its station didn't answer: let the line go.
                counters_.noReplies += 1
                state = .idle
            }
        case .frame(let id, let stage, let final, let bytes):
            counters_.framesIn += 1
            let to = bytes[0], from = bytes[2]
            if case .holding(var transaction, _) = state, transaction.remote == from, transaction.local == to,
               stage == transaction.stage + 1 {
                // The answer: stop the flags and put it on the line.
                transaction.stage = stage
                transaction.id = id
                queueFrame(bytes, as: from)
                state = final ? .idle : .awaitingLocal(transaction, since: .max)
            } else if stage == 0, let shared, !shared.contains(to) {
                // For a station that isn't shared: as if it weren't there.
                refuse(message)
            } else if stage == 0 {
                // A scout from a remote station.
                if case .idle = state, waiting.allSatisfy({ if case .frame = $0.message { false } else { true } }) {
                    waiting.append((message, time))
                } else {
                    refuse(message)
                }
            }
            // Anything else is stale (a transaction given up on).
        }
    }

    /// Puts a frame from the room on the line (it's quiet).
    private func transmitFromRoom(_ message: EconetGatewayMessage, at time: UInt64) {
        switch message {
        case .broadcast(let bytes):
            queueFrame(bytes, as: bytes[2])
        case .frame(let id, let stage, _, let bytes):
            let transaction = Transaction(local: bytes[0], remote: bytes[2], id: id, stage: stage,
                                          finalStage: Transaction.finalStage(scout: bytes))
            queueFrame(bytes, as: bytes[2])
            state = .awaitingLocal(transaction, since: .max)
        case .noReply:
            break
        }
        transmitAt = max(transmitAt, time)
    }

    private func refuse(_ message: EconetGatewayMessage) {
        guard case .frame(let id, _, _, let bytes) = message else { return }
        counters_.refusedBusy += 1
        send(.noReply(transaction: id, from: bytes[0], to: bytes[2]))
    }

    private func queueFrame(_ bytes: [UInt8], as station: UInt8) {
        outgoing.append((station, .flag))
        outgoing.append(contentsOf: bytes.map { (station, EconetSymbol.byte($0)) })
        outgoing.append((station, .check))
        outgoing.append((station, .check))
        outgoing.append((station, .flag))
    }

    private func publish() {
        let activity: Activity = switch state {
        case .idle: .idle
        case .holding(let t, _): .holding(station: t.remote)
        case .awaitingLocal(let t, _): .awaitingLocal(station: t.local)
        }
        let counters = counters_
        lock.withLock {
            publishedActivity = activity
            publishedCounters = counters
        }
    }
}

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
