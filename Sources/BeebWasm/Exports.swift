// The BeebWasm ABI: flat C functions over opaque machine handles, exported
// from the WebAssembly module (and callable from Swift, so native tests run
// the very same code). docs/wasm.md describes it; web/src/beeb-wasm.ts
// wraps it for JavaScript.
//
// Conventions:
// - Functions that can fail return an Int32: 0 (or a non-negative result)
//   for success, or a negative `BeebStatus`, with a message from
//   beeb_error_ptr/beeb_error_len.
// - Bytes passed in are copied before the call returns; the caller frees
//   its buffer (beeb_alloc/beeb_free give it one in linear memory).
// - Bytes passed out go in the result buffer: the call returns their length
//   and beeb_result_ptr says where they are, until the next call that
//   produces a result.
// - beeb_video_frame's pointer stays valid until the machine is released.
// - Nothing traps on bad input: handles, lengths, addresses, models and
//   formats are checked.

import BeebCore
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum BeebStatus: Int32 {
    case ok = 0
    case invalidHandle = -1
    case invalidArgument = -2
    /// The machine hasn't been powered on (it needs an OS ROM first).
    case notReady = -3
    /// A ROM, disc image or save state that isn't one.
    case badData = -4
    case unsupported = -5
    case limitReached = -6
}

/// The ABI's version: changes when a function changes meaning.
let beebABIVersion: Int32 = 2

enum Limits {
    static let machines = 16
    static let romBytes = 0x4000
    static let discBytes = 4 << 20
    static let stateBytes = 64 << 20
    static let textBytes = 64 << 10
    /// 10 seconds of the BBC's time per call.
    static let runCycles: Int32 = 20_000_000
}

nonisolated(unsafe) var machines: [Int32: WasmMachine] = [:]
/// Machines and networks share the numbering, so a handle is one or the
/// other.
nonisolated(unsafe) var nextHandle: Int32 = 0
private nonisolated(unsafe) var errorMessage = ResultBuffer()
nonisolated(unsafe) var result = ResultBuffer()

/// Bytes for the host to read: the last result, or the last error's
/// message.
struct ResultBuffer {
    private(set) var pointer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 8)
    private(set) var count = 0
    private var capacity = 1

    mutating func set<C: Collection<UInt8>>(_ bytes: C) {
        if bytes.count > capacity {
            pointer.deallocate()
            capacity = bytes.count
            pointer = .allocate(byteCount: capacity, alignment: 8)
        }
        count = bytes.count
        UnsafeMutableRawBufferPointer(start: pointer, count: count).copyBytes(from: bytes)
    }
}

func fail(_ status: BeebStatus, _ message: String) -> Int32 {
    errorMessage.set(Array(message.utf8))
    return status.rawValue
}

func lookup(_ handle: Int32) -> WasmMachine? {
    machines[handle]
}

/// The machine, powered on, or an error status.
private func running(_ handle: Int32) -> Result<(WasmMachine, BBCMicro), Failure> {
    guard let m = lookup(handle) else { return .failure(Failure(.invalidHandle, "no machine \(handle)")) }
    guard let machine = m.machine else { return .failure(Failure(.notReady, "machine \(handle) isn't powered on")) }
    return .success((m, machine))
}

private struct Failure: Error {
    var status: BeebStatus
    var message: String
    init(_ status: BeebStatus, _ message: String) {
        self.status = status
        self.message = message
    }
}

/// `body` on the powered-on machine, or the error status.
func withRunning(_ handle: Int32, _ body: (WasmMachine, BBCMicro) -> Int32) -> Int32 {
    switch running(handle) {
    case .success(let (m, machine)): body(m, machine)
    case .failure(let f): fail(f.status, f.message)
    }
}

/// Copies `count` bytes from the caller, checking the pointer and size.
func bytes(_ pointer: UnsafeRawPointer?, _ count: Int32, limit: Int) -> [UInt8]? {
    guard count >= 0, Int(count) <= limit, count == 0 || pointer != nil else { return nil }
    guard let pointer, count > 0 else { return [] }
    return [UInt8](UnsafeRawBufferPointer(start: pointer, count: Int(count)))
}

private let models: [BBCMicro.Model] = [.modelA, .modelB, .bPlus, .master128, .masterCompact]
private let formats: [Disc.ImageFormat] = [.ssd, .dsd, .adf, .adl, .img, .dos]

// MARK: Module

@_expose(wasm, "beeb_abi_version")
@_cdecl("beeb_abi_version")
public func beeb_abi_version() -> Int32 { beebABIVersion }

/// Linear memory for the host to pass bytes in: `size` bytes, or null.
@_expose(wasm, "beeb_alloc")
@_cdecl("beeb_alloc")
public func beeb_alloc(_ size: Int32) -> UnsafeMutableRawPointer? {
    guard size > 0 else { return nil }
    return .allocate(byteCount: Int(size), alignment: 16)
}

@_expose(wasm, "beeb_free")
@_cdecl("beeb_free")
public func beeb_free(_ pointer: UnsafeMutableRawPointer?) {
    pointer?.deallocate()
}

/// The last error's message (UTF-8), and its length.
@_expose(wasm, "beeb_error_ptr")
@_cdecl("beeb_error_ptr")
public func beeb_error_ptr() -> UnsafeRawPointer? { UnsafeRawPointer(errorMessage.pointer) }

@_expose(wasm, "beeb_error_len")
@_cdecl("beeb_error_len")
public func beeb_error_len() -> Int32 { Int32(errorMessage.count) }

/// Where the last result's bytes are.
@_expose(wasm, "beeb_result_ptr")
@_cdecl("beeb_result_ptr")
public func beeb_result_ptr() -> UnsafeRawPointer? { UnsafeRawPointer(result.pointer) }

@_expose(wasm, "beeb_machine_count")
@_cdecl("beeb_machine_count")
public func beeb_machine_count() -> Int32 { Int32(machines.count) }

// MARK: Machines

/// A new machine of `model` (0 Model A, 1 Model B, 2 B+, 3 Master 128,
/// 4 Master Compact), without ROMs: give it an OS (and sideways ROMs) with
/// beeb_load_rom, then beeb_power_on. Returns its handle (positive).
@_expose(wasm, "beeb_create")
@_cdecl("beeb_create")
public func beeb_create(_ model: Int32) -> Int32 {
    guard models.indices.contains(Int(model)) else { return fail(.unsupported, "no model \(model)") }
    guard machines.count < Limits.machines else { return fail(.limitReached, "at most \(Limits.machines) machines") }
    let handle = newHandle()
    machines[handle] = WasmMachine(model: models[Int(model)])
    return handle
}

@_expose(wasm, "beeb_release")
@_cdecl("beeb_release")
public func beeb_release(_ handle: Int32) -> Int32 {
    guard let m = machines.removeValue(forKey: handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    m.network?.remove(handle)
    return 0
}

/// A handle for a new machine or network.
func newHandle() -> Int32 {
    repeat {
        nextHandle = nextHandle == Int32.max ? 1 : nextHandle + 1
    } while machines[nextHandle] != nil || networks[nextHandle] != nil
    return nextHandle
}

/// Puts a ROM in the configuration: `slot` -1 for the OS, 0-15 for a
/// sideways bank (an empty ROM empties it). A machine that's on is power
/// cycled with it.
@_expose(wasm, "beeb_load_rom")
@_cdecl("beeb_load_rom")
public func beeb_load_rom(_ handle: Int32, _ slot: Int32, _ pointer: UnsafeRawPointer?, _ count: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard (-1..<16).contains(slot) else { return fail(.invalidArgument, "no ROM slot \(slot)") }
    guard let rom = bytes(pointer, count, limit: Limits.romBytes) else {
        return fail(.badData, "a ROM is at most 16K")
    }
    if slot == -1 {
        guard rom.count == Limits.romBytes else { return fail(.badData, "the OS ROM must be 16K") }
        m.configuration.os = rom
    } else {
        m.configuration.sidewaysROMs[Int(slot)] = rom.isEmpty ? nil : rom
    }
    if m.machine != nil { m.powerOn() }
    return 0
}

/// The Master's clock at power on (and now, if it's on): year 0-99,
/// month 1-12, day 1-31, day of week 1-7 (Sunday 1), hours, minutes,
/// seconds.
@_expose(wasm, "beeb_set_rtc")
@_cdecl("beeb_set_rtc")
public func beeb_set_rtc(_ handle: Int32, _ year: Int32, _ month: Int32, _ day: Int32, _ dayOfWeek: Int32,
                         _ hours: Int32, _ minutes: Int32, _ seconds: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard (0...99).contains(year), (1...12).contains(month), (1...31).contains(day), (1...7).contains(dayOfWeek),
          (0...23).contains(hours), (0...59).contains(minutes), (0...59).contains(seconds) else {
        return fail(.invalidArgument, "not a time")
    }
    m.rtc = .init(year: Int(year), month: Int(month), day: Int(day), dayOfWeek: Int(dayOfWeek),
                  hours: Int(hours), minutes: Int(minutes), seconds: Int(seconds))
    m.machine?.rtc.setTime(year: m.rtc.year, month: m.rtc.month, dayOfMonth: m.rtc.day, dayOfWeek: m.rtc.dayOfWeek,
                           hours: m.rtc.hours, minutes: m.rtc.minutes, seconds: m.rtc.seconds)
    return 0
}

/// Switches on (or power cycles) the machine. Discs stay in the drives.
@_expose(wasm, "beeb_power_on")
@_cdecl("beeb_power_on")
public func beeb_power_on(_ handle: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard m.configuration.os.count == Limits.romBytes else { return fail(.notReady, "no OS ROM") }
    m.powerOn()
    return 0
}

/// 0: power cycle; 1: Break; 2: Ctrl-Break; 3: Shift-Break (boots the disc).
@_expose(wasm, "beeb_reset")
@_cdecl("beeb_reset")
public func beeb_reset(_ handle: Int32, _ kind: Int32) -> Int32 {
    withRunning(handle) { m, machine in
        switch kind {
        case 0: m.powerOn()
        case 1: machine.pressBreak()
        case 2: machine.ctrlBreak()
        case 3: machine.shiftBreak()
        default: return fail(.invalidArgument, "no reset \(kind)")
        }
        return 0
    }
}

// MARK: Running

/// Runs up to `cycles` 2MHz cycles (at most 20,000,000). Returns how many
/// ran: fewer if the debugger stopped the machine.
@_expose(wasm, "beeb_run")
@_cdecl("beeb_run")
public func beeb_run(_ handle: Int32, _ cycles: Int32) -> Int32 {
    guard (0...Limits.runCycles).contains(cycles) else {
        return fail(.invalidArgument, "run 0-\(Limits.runCycles) cycles")
    }
    return withRunning(handle) { m, machine in
        // A network's machines run together, by beeb_network_run.
        guard m.network == nil else { return fail(.invalidArgument, "machine \(handle) is on a network: run the network") }
        return Int32(machine.run(cycles: Int(cycles)))
    }
}

/// 2MHz cycles since power on (exact to 2^53).
@_expose(wasm, "beeb_cycles")
@_cdecl("beeb_cycles")
public func beeb_cycles(_ handle: Int32) -> Double {
    lookup(handle)?.machine.map { Double($0.cycles) } ?? -1
}

/// Bits: 1 on, 2 stopped by the debugger, 4 Caps Lock light, 8 Shift
/// Lock light, 16 and 32 drive 0 and 1 lights, 64 cassette motor. Or a
/// negative status.
@_expose(wasm, "beeb_status")
@_cdecl("beeb_status")
public func beeb_status(_ handle: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard let machine = m.machine else { return 0 }
    let lights = machine.lights
    var status: Int32 = 1
    if machine.isStoppedByDebugger { status |= 2 }
    if lights.capsLock { status |= 4 }
    if lights.shiftLock { status |= 8 }
    if lights.drives[0] { status |= 16 }
    if lights.drives[1] { status |= 32 }
    if lights.cassetteMotor { status |= 64 }
    return status
}

/// The 6502's registers, 8 bytes at `out`: PC (low, high), A, X, Y, S, P,
/// and 0.
@_expose(wasm, "beeb_cpu_state")
@_cdecl("beeb_cpu_state")
public func beeb_cpu_state(_ handle: Int32, _ out: UnsafeMutableRawPointer?) -> Int32 {
    guard let out else { return fail(.invalidArgument, "no buffer") }
    return withRunning(handle) { _, machine in
        let c = machine.cpu
        let bytes: [UInt8] = [UInt8(c.pc & 0xFF), UInt8(c.pc >> 8), c.a, c.x, c.y, c.s, c.p, 0]
        bytes.withUnsafeBytes { out.copyMemory(from: $0.baseAddress!, byteCount: 8) }
        return 0
    }
}

/// Reads `count` bytes from `address` (wrapping at &FFFF) into `out`
/// without side effects. Space 0: as the CPU sees memory (I/O as the
/// devices would answer); 1: the RAM the video hardware sees.
@_expose(wasm, "beeb_read_memory")
@_cdecl("beeb_read_memory")
public func beeb_read_memory(_ handle: Int32, _ space: Int32, _ address: Int32, _ count: Int32,
                             _ out: UnsafeMutableRawPointer?) -> Int32 {
    guard (0...0xFFFF).contains(address), (0...0x10000).contains(count), count == 0 || out != nil else {
        return fail(.invalidArgument, "read 0-65536 bytes from &0000-&FFFF")
    }
    guard (0...1).contains(space) else { return fail(.invalidArgument, "no address space \(space)") }
    return withRunning(handle) { _, machine in
        guard let out else { return 0 }
        let bytes = out.assumingMemoryBound(to: UInt8.self)
        for i in 0..<Int(count) {
            let a = UInt16(truncatingIfNeeded: Int(address) + i)
            bytes[i] = space == 0 ? machine.peek(a) : machine.peekScreen(a)
        }
        return count
    }
}

// MARK: Input

/// Presses (`down` 1) or releases (0) the key at `code` in the keyboard
/// matrix: row << 4 | column, as BeebKey has it; 0x7F is Break. It
/// happens at the current cycle, before the next beeb_run.
@_expose(wasm, "beeb_set_key")
@_cdecl("beeb_set_key")
public func beeb_set_key(_ handle: Int32, _ code: Int32, _ down: Int32) -> Int32 {
    guard (0..<0x80).contains(code), code & 0x0F < 13 || code == 0x7F else {
        return fail(.invalidArgument, "no key \(code)")
    }
    return withRunning(handle) { _, machine in
        machine.setKey(BeebKey(rawValue: UInt8(code)), down: down != 0)
        return 0
    }
}

@_expose(wasm, "beeb_release_all_keys")
@_cdecl("beeb_release_all_keys")
public func beeb_release_all_keys(_ handle: Int32) -> Int32 {
    withRunning(handle) { _, machine in
        machine.releaseAllKeys()
        return 0
    }
}

/// Types UTF-8 text through the keyboard, a key at a time from now, as
/// the machine runs ("\n" is Return).
@_expose(wasm, "beeb_type")
@_cdecl("beeb_type")
public func beeb_type(_ handle: Int32, _ pointer: UnsafeRawPointer?, _ count: Int32) -> Int32 {
    guard let text = bytes(pointer, count, limit: Limits.textBytes) else { return fail(.invalidArgument, "text too long") }
    return withRunning(handle) { _, machine in
        machine.type(String(decoding: text, as: UTF8.self))
        return 0
    }
}

/// 1 while typed text is still going in.
@_expose(wasm, "beeb_is_typing")
@_cdecl("beeb_is_typing")
public func beeb_is_typing(_ handle: Int32) -> Int32 {
    withRunning(handle) { _, machine in machine.isTyping ? 1 : 0 }
}

// MARK: Discs

/// Puts a disc image in drive 0 or 1. `format`: 0 .ssd, 1 .dsd, 2 .adf,
/// 3 .adl, 4 .img (DOS Plus 800K), 5 .dos (720K).
@_expose(wasm, "beeb_insert_disc")
@_cdecl("beeb_insert_disc")
public func beeb_insert_disc(_ handle: Int32, _ drive: Int32, _ format: Int32, _ pointer: UnsafeRawPointer?,
                             _ count: Int32) -> Int32 {
    guard (0...1).contains(drive) else { return fail(.invalidArgument, "no drive \(drive)") }
    guard formats.indices.contains(Int(format)) else { return fail(.unsupported, "no disc format \(format)") }
    guard let image = bytes(pointer, count, limit: Limits.discBytes) else { return fail(.badData, "disc image too big") }
    return withRunning(handle) { _, machine in
        do {
            machine.insertDisc(try Disc.fromImage(image, format: formats[Int(format)]), drive: Int(drive))
            return 0
        } catch {
            return fail(.badData, "not a .\(formats[Int(format)].rawValue) image: \(error)")
        }
    }
}

@_expose(wasm, "beeb_eject_disc")
@_cdecl("beeb_eject_disc")
public func beeb_eject_disc(_ handle: Int32, _ drive: Int32) -> Int32 {
    guard (0...1).contains(drive) else { return fail(.invalidArgument, "no drive \(drive)") }
    return withRunning(handle) { _, machine in
        machine.insertDisc(nil, drive: Int(drive))
        return 0
    }
}

/// The disc in a drive, with anything the BBC wrote to it, as an image
/// in the result buffer. Returns its length.
@_expose(wasm, "beeb_export_disc")
@_cdecl("beeb_export_disc")
public func beeb_export_disc(_ handle: Int32, _ drive: Int32, _ format: Int32) -> Int32 {
    guard (0...1).contains(drive) else { return fail(.invalidArgument, "no drive \(drive)") }
    guard formats.indices.contains(Int(format)) else { return fail(.unsupported, "no disc format \(format)") }
    return withRunning(handle) { _, machine in
        guard let disc = machine.drives[Int(drive)].disc else { return fail(.invalidArgument, "drive \(drive) is empty") }
        do {
            let image = try disc.toImage(formats[Int(format)])
            result.set(image)
            return Int32(image.count)
        } catch {
            return fail(.unsupported, "the disc won't make a .\(formats[Int(format)].rawValue) image: \(error)")
        }
    }
}

// MARK: Video

@_expose(wasm, "beeb_video_width")
@_cdecl("beeb_video_width")
public func beeb_video_width() -> Int32 { Int32(TVOutput.width) }

@_expose(wasm, "beeb_video_height")
@_cdecl("beeb_video_height")
public func beeb_video_height() -> Int32 { Int32(TVOutput.height) }

/// Complete frames so far (the TV's count: one per vertical retrace).
@_expose(wasm, "beeb_video_frame_count")
@_cdecl("beeb_video_frame_count")
public func beeb_video_frame_count(_ handle: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    return Int32(truncatingIfNeeded: m.tv.frameCount & 0x7FFF_FFFF)
}

/// The last complete frame: width x height RGBA8 pixels (bytes R, G, B,
/// 255), rows top to bottom, no padding. The pointer is the machine's
/// own buffer: valid until it's released, rewritten by the next call.
@_expose(wasm, "beeb_video_frame")
@_cdecl("beeb_video_frame")
public func beeb_video_frame(_ handle: Int32) -> UnsafeRawPointer? {
    guard let m = lookup(handle) else {
        _ = fail(.invalidHandle, "no machine \(handle)")
        return nil
    }
    return UnsafeRawPointer(m.frameRGBA())
}

/// FNV-1a of the last frame's pixels, for comparing hosts.
@_expose(wasm, "beeb_video_frame_hash")
@_cdecl("beeb_video_frame_hash")
public func beeb_video_frame_hash(_ handle: Int32) -> UInt32 {
    lookup(handle)?.frameHash() ?? 0
}

/// The screen's text (BeebCore's screenText), UTF-8 lines separated by
/// "\n", in the result buffer. Returns its length.
@_expose(wasm, "beeb_screen_text")
@_cdecl("beeb_screen_text")
public func beeb_screen_text(_ handle: Int32) -> Int32 {
    withRunning(handle) { _, machine in
        let text = Array(machine.screenText().joined(separator: "\n").utf8)
        result.set(text)
        return Int32(text.count)
    }
}

// MARK: Save states

/// The whole machine (its configuration and ROMs, discs and every
/// device) as a save state, MacBeeb's .beebstate format uncompressed, in
/// the result buffer. Returns its length.
@_expose(wasm, "beeb_save_state")
@_cdecl("beeb_save_state")
public func beeb_save_state(_ handle: Int32) -> Int32 {
    withRunning(handle) { _, machine in
        do {
            let data = try SaveStateFile(machine).portableData()
            guard data.count <= Limits.stateBytes else { return fail(.limitReached, "the state is too big") }
            result.set(data)
            return Int32(data.count)
        } catch {
            return fail(.unsupported, "couldn't save the state: \(error)")
        }
    }
}

/// Replaces the machine with the one in a save state (from
/// beeb_save_state, or MacBeeb's own when it was built with the same
/// compression).
@_expose(wasm, "beeb_restore_state")
@_cdecl("beeb_restore_state")
public func beeb_restore_state(_ handle: Int32, _ pointer: UnsafeRawPointer?, _ count: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard let data = bytes(pointer, count, limit: Limits.stateBytes) else { return fail(.badData, "the state is too big") }
    do {
        try m.restore(SaveStateFile(data: Data(data)))
        return 0
    } catch {
        return fail(.badData, "not a save state MacBeeb can restore: \(error)")
    }
}
