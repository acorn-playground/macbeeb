// The ABI's Econet networks (see Exports.swift for its conventions): machines
// on one line, run together in lockstep as MacBeeb's NetworkHost runs them,
// and an Internet gateway on the line that stands in for stations elsewhere
// (BeebCore's EconetGateway, speaking the room protocol's wire format).
//
// A network's machines run only through beeb_network_run: each quantum
// (the line's delay, 32 cycles), every one runs it in turn, then the line
// delivers what they sent. What a gateway sends to the room is collected for
// the host to take after each run; what the room sends, the host gives it.

import BeebCore
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

nonisolated(unsafe) var networks: [Int32: WasmNetwork] = [:]

final class WasmNetwork {
    let bus: EconetBus
    /// The machines on it, by handle, in the order they joined, and the
    /// BBCMicro each had on the line (a power cycle makes a new one).
    private(set) var members: [Int32] = []
    private var onLine: [Int32: BBCMicro] = [:]
    private(set) var gateway: EconetGateway?
    /// The gateway's messages for the room, encoded, not yet taken.
    var outbox: [Data] = []
    /// Frames seen on the line (each ends with two check bytes), and
    /// byte-times spoiled by collisions.
    private(set) var checkBytes = 0
    private(set) var collisions = 0

    init(clockRate: Int?) {
        bus = EconetBus(clockRate: clockRate)
        bus.observer = { [unowned self] event in
            if case .check = event.symbol { checkBytes += 1 }
            if event.collided { collisions += 1 }
        }
    }

    func add(_ handle: Int32, _ machine: WasmMachine) {
        guard !members.contains(handle) else { return }
        machine.network?.remove(handle)
        members.append(handle)
        machine.network = self
    }

    func remove(_ handle: Int32) {
        members.removeAll { $0 == handle }
        if let old = onLine.removeValue(forKey: handle) { bus.detach(old) }
        machines[handle]?.network = nil
    }

    /// The line's told of machines that changed (a power cycle, a restored
    /// state) since the last run.
    private func attachMachines() -> [BBCMicro] {
        var running: [BBCMicro] = []
        var changed = false
        for handle in members {
            guard let machine = machines[handle]?.machine else { continue }
            if onLine[handle] !== machine {
                if let old = onLine[handle] { bus.detach(old) }
                bus.attach(machine)
                onLine[handle] = machine
                changed = true
            }
            running.append(machine)
        }
        if changed { bus.setRunning { _ in true } }
        return running
    }

    /// Runs every machine `cycles` (rounded up to whole quanta), or
    /// (`untilHolding`) until the gateway's holding the line for an answer
    /// from the room. Returns the cycles run.
    func run(_ cycles: Int, untilHolding: Bool = false) -> Int {
        let running = attachMachines()
        let quantum = bus.delay
        var done = 0
        while done < cycles {
            if untilHolding, let gateway, case .holding = gateway.activity { break }
            bus.beginQuantum()
            for machine in running { machine.run(cycles: quantum) }
            bus.endQuantum(cycles: quantum)
            done += quantum
        }
        return done
    }

    func attachGateway() {
        guard gateway == nil else { return }
        let gateway = EconetGateway()
        gateway.send = { [unowned self] message in outbox.append(EconetTraffic.encode(message)) }
        bus.attach(device: gateway)
        self.gateway = gateway
    }

    func detachGateway() {
        guard let gateway else { return }
        bus.detach(device: gateway)
        self.gateway = nil
        outbox = []
    }
}

private func network(_ handle: Int32) -> WasmNetwork? {
    networks[handle]
}

private func noNetwork(_ handle: Int32) -> Int32 {
    fail(.invalidHandle, "no network \(handle)")
}

/// Station numbers from the host: `count` bytes, each 1-254.
private func stations(_ pointer: UnsafeRawPointer?, _ count: Int32) -> Set<UInt8>? {
    guard let list = bytes(pointer, count, limit: 254), list.allSatisfy({ (1...254).contains($0) }) else { return nil }
    return Set(list)
}

/// A new Econet: a line with a clock of `clockRate` bits a second (200,000
/// is usual), or none (0). Returns its handle.
@_expose(wasm, "beeb_network_create")
@_cdecl("beeb_network_create")
public func beeb_network_create(_ clockRate: Int32) -> Int32 {
    guard (0...2_000_000).contains(clockRate) else { return fail(.invalidArgument, "a clock of 0-2,000,000 bits a second") }
    guard networks.count < 8 else { return fail(.limitReached, "at most 8 networks") }
    let handle = newHandle()
    networks[handle] = WasmNetwork(clockRate: clockRate == 0 ? nil : Int(clockRate))
    return handle
}

/// Takes the network apart; its machines carry on alone.
@_expose(wasm, "beeb_network_release")
@_cdecl("beeb_network_release")
public func beeb_network_release(_ handle: Int32) -> Int32 {
    guard let net = networks.removeValue(forKey: handle) else { return noNetwork(handle) }
    for member in net.members { net.remove(member) }
    net.detachGateway()
    return 0
}

/// Plugs a machine in (off any other network). Its Econet module, if it
/// has one, joins the line; without one it still runs with the others.
@_expose(wasm, "beeb_network_add")
@_cdecl("beeb_network_add")
public func beeb_network_add(_ handle: Int32, _ machine: Int32) -> Int32 {
    guard let net = network(handle) else { return noNetwork(handle) }
    guard let m = lookup(machine) else { return fail(.invalidHandle, "no machine \(machine)") }
    net.add(machine, m)
    return 0
}

@_expose(wasm, "beeb_network_remove")
@_cdecl("beeb_network_remove")
public func beeb_network_remove(_ handle: Int32, _ machine: Int32) -> Int32 {
    guard let net = network(handle) else { return noNetwork(handle) }
    guard net.members.contains(machine) else { return fail(.invalidArgument, "machine \(machine) isn't on network \(handle)") }
    net.remove(machine)
    return 0
}

/// Runs the network's machines together for `cycles` (at most 20,000,000;
/// rounded up to whole 32-cycle quanta). Returns the cycles run.
@_expose(wasm, "beeb_network_run")
@_cdecl("beeb_network_run")
public func beeb_network_run(_ handle: Int32, _ cycles: Int32) -> Int32 {
    guard let net = network(handle) else { return noNetwork(handle) }
    guard (0...Limits.runCycles).contains(cycles) else { return fail(.invalidArgument, "run 0-\(Limits.runCycles) cycles") }
    return Int32(net.run(Int(cycles)))
}

/// As beeb_network_run, but stopping (at the end of a quantum) once the
/// gateway's holding the line for an answer from the room: a host that
/// runs the network only when there's something to do stops there, and
/// carries on when the answer comes. Returns the cycles run (0 if it's
/// holding already).
@_expose(wasm, "beeb_network_run_until_holding")
@_cdecl("beeb_network_run_until_holding")
public func beeb_network_run_until_holding(_ handle: Int32, _ cycles: Int32) -> Int32 {
    guard let net = network(handle) else { return noNetwork(handle) }
    guard (0...Limits.runCycles).contains(cycles) else { return fail(.invalidArgument, "run 0-\(Limits.runCycles) cycles") }
    return Int32(net.run(Int(cycles), untilHolding: true))
}

/// Frames seen on the line since the network began, and (with `which` 1)
/// byte-times spoiled by collisions.
@_expose(wasm, "beeb_network_count")
@_cdecl("beeb_network_count")
public func beeb_network_count(_ handle: Int32, _ which: Int32) -> Int32 {
    guard let net = network(handle) else { return noNetwork(handle) }
    return Int32(truncatingIfNeeded: which == 1 ? net.collisions : net.checkBytes / 2)
}

// MARK: The Internet gateway

/// Puts an Internet gateway on the line (or takes it off, `on` 0).
@_expose(wasm, "beeb_gateway_attach")
@_cdecl("beeb_gateway_attach")
public func beeb_gateway_attach(_ handle: Int32, _ on: Int32) -> Int32 {
    guard let net = network(handle) else { return noNetwork(handle) }
    if on != 0 { net.attachGateway() } else { net.detachGateway() }
    return 0
}

/// The stations elsewhere that the gateway answers for (`count` bytes).
@_expose(wasm, "beeb_gateway_set_remote")
@_cdecl("beeb_gateway_set_remote")
public func beeb_gateway_set_remote(_ handle: Int32, _ pointer: UnsafeRawPointer?, _ count: Int32) -> Int32 {
    guard let gateway = network(handle)?.gateway else { return fail(.invalidHandle, "no gateway on network \(handle)") }
    guard let list = stations(pointer, count) else { return fail(.invalidArgument, "stations are 1-254") }
    gateway.remoteStations = list
    return 0
}

/// The local stations shared with the room (`count` bytes), or all of them
/// (`all` 1). Frames from the room for others are refused, and theirs
/// aren't sent.
@_expose(wasm, "beeb_gateway_set_shared")
@_cdecl("beeb_gateway_set_shared")
public func beeb_gateway_set_shared(_ handle: Int32, _ pointer: UnsafeRawPointer?, _ count: Int32, _ all: Int32) -> Int32 {
    guard let gateway = network(handle)?.gateway else { return fail(.invalidHandle, "no gateway on network \(handle)") }
    if all != 0 {
        gateway.sharedStations = nil
        return 0
    }
    guard let list = stations(pointer, count) else { return fail(.invalidArgument, "stations are 1-254") }
    gateway.sharedStations = list
    return 0
}

/// A message from the room, as it came (the protocol's binary message,
/// version 1). It's acted on as the network runs.
@_expose(wasm, "beeb_gateway_receive")
@_cdecl("beeb_gateway_receive")
public func beeb_gateway_receive(_ handle: Int32, _ pointer: UnsafeRawPointer?, _ count: Int32) -> Int32 {
    guard let gateway = network(handle)?.gateway else { return fail(.invalidHandle, "no gateway on network \(handle)") }
    guard let data = bytes(pointer, count, limit: EconetTraffic.headerBytes + EconetTraffic.maxFrameBytes) else {
        return fail(.badData, "too big for a message")
    }
    do {
        gateway.receive(try EconetTraffic.decode(Data(data)))
        return 0
    } catch {
        return fail(.badData, "not a message the gateway understands: \(error)")
    }
}

/// The gateway's messages for the room since the last call, in the result
/// buffer: each a 4-byte big-endian length then the message. Returns the
/// buffer's length.
@_expose(wasm, "beeb_gateway_take")
@_cdecl("beeb_gateway_take")
public func beeb_gateway_take(_ handle: Int32) -> Int32 {
    guard let net = network(handle) else { return noNetwork(handle) }
    var out: [UInt8] = []
    for message in net.outbox {
        let n = UInt32(message.count)
        out += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        out += message
    }
    net.outbox = []
    result.set(out)
    return Int32(out.count)
}

/// What the gateway's done: 7 int32s at `out` (frames out, frames in,
/// broadcasts out, broadcasts in, no replies, refused as busy, timeouts),
/// and its activity, returned: 0 idle, 1 holding the line for a station
/// elsewhere, 2 waiting for a local station's answer.
@_expose(wasm, "beeb_gateway_status")
@_cdecl("beeb_gateway_status")
public func beeb_gateway_status(_ handle: Int32, _ out: UnsafeMutableRawPointer?) -> Int32 {
    guard let gateway = network(handle)?.gateway else { return fail(.invalidHandle, "no gateway on network \(handle)") }
    if let out {
        let c = gateway.counters
        let values: [Int32] = [c.framesOut, c.framesIn, c.broadcastsOut, c.broadcastsIn, c.noReplies, c.refusedBusy, c.timeouts]
            .map { Int32(truncatingIfNeeded: $0) }
        values.withUnsafeBytes { out.copyMemory(from: $0.baseAddress!, byteCount: 28) }
    }
    return switch gateway.activity {
    case .idle: 0
    case .holding: 1
    case .awaitingLocal: 2
    }
}
