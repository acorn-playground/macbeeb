// The ABI's sound, joysticks and Econet station number (see Exports.swift
// for its conventions).

import BeebCore
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: Sound

/// Starts the machine making sound, mono, at `rate` samples a second
/// (8,000-192,000), for beeb_audio_read to take; 0 stops it. The sound
/// chip's output is filtered and mixed down to the rate as the Mac app's is.
@_expose(wasm, "beeb_audio_start")
@_cdecl("beeb_audio_start")
public func beeb_audio_start(_ handle: Int32, _ rate: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard rate == 0 || (8000...192_000).contains(rate) else { return fail(.invalidArgument, "a rate of 8,000-192,000") }
    m.setAudio(rate: rate == 0 ? nil : Int(rate))
    return 0
}

/// Takes up to `count` samples (32-bit floats, -1 to 1) made since the last
/// call, into `out`. Returns how many. Samples not taken within two
/// seconds are dropped.
@_expose(wasm, "beeb_audio_read")
@_cdecl("beeb_audio_read")
public func beeb_audio_read(_ handle: Int32, _ out: UnsafeMutableRawPointer?, _ count: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard count >= 0, count == 0 || out != nil else { return fail(.invalidArgument, "no buffer") }
    guard let ring = m.audio?.ring, let out else { return 0 }
    let n = min(Int(count), ring.count)
    guard n > 0 else { return 0 }
    let buffer = UnsafeMutableBufferPointer(start: out.bindMemory(to: Float.self, capacity: n), count: n)
    return Int32(ring.read(into: buffer))
}

// MARK: Joysticks

/// Joystick 0 or 1 (on the analogue port; on the Master Compact, 0 is its
/// digital joystick): `x` and `y` from -1 (left, down) to 1 (right, up), and
/// the fire button. It stays as set, through power cycles, until set again.
@_expose(wasm, "beeb_set_joystick")
@_cdecl("beeb_set_joystick")
public func beeb_set_joystick(_ handle: Int32, _ index: Int32, _ x: Double, _ y: Double, _ fire: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard index == 0 || index == 1 else { return fail(.invalidArgument, "no joystick \(index)") }
    guard x.isFinite, y.isFinite else { return fail(.invalidArgument, "not a position") }
    let stick = (x: max(-1, min(1, x)), y: max(-1, min(1, y)), fire: fire != 0)
    m.joysticks[Int(index)] = stick
    m.machine?.setJoystick(Int(index), x: stick.x, y: stick.y, fire: stick.fire)
    return 0
}

// MARK: Econet

/// Fits an Econet module with station number `station` (1-254), or takes it
/// out (0). A machine that's on is power cycled. The B needs DNFS in place
/// of its DFS, and the Masters ANFS, among its ROMs for the network.
@_expose(wasm, "beeb_set_econet_station")
@_cdecl("beeb_set_econet_station")
public func beeb_set_econet_station(_ handle: Int32, _ station: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard (0...254).contains(station) else { return fail(.invalidArgument, "station 1-254, or 0 for none") }
    guard station == 0 || m.configuration.model != .modelA else { return fail(.unsupported, "the Model A takes no Econet module") }
    m.configuration.econetStation = station == 0 ? nil : Int(station)
    if m.machine != nil { m.powerOn() }
    return 0
}

// MARK: Hardware

/// Fits a 6502 Second Processor on the Tube, with its client ROM (TUBE110,
/// 2K), or takes it out (no ROM). A machine that's on is power cycled.
@_expose(wasm, "beeb_set_second_processor")
@_cdecl("beeb_set_second_processor")
public func beeb_set_second_processor(_ handle: Int32, _ pointer: UnsafeRawPointer?, _ count: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard let rom = bytes(pointer, count, limit: Limits.romBytes) else { return fail(.badData, "a ROM is at most 16K") }
    m.configuration.secondProcessorROM = rom.isEmpty ? nil : rom
    m.configuration.coprocessor = .mos6502
    if m.machine != nil { m.powerOn() }
    return 0
}

/// Sideways RAM in the banks set in `banks` (bit n: bank n), in place of
/// the model's own (as a board of sideways RAM, such as a 16K one in bank
/// 4 for Elite on a Model B). A machine that's on is power cycled.
@_expose(wasm, "beeb_set_sideways_ram")
@_cdecl("beeb_set_sideways_ram")
public func beeb_set_sideways_ram(_ handle: Int32, _ banks: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard (0...0xFFFF).contains(banks) else { return fail(.invalidArgument, "banks are bits 0-15") }
    m.configuration.sidewaysRAMBanks = Set((0..<16).filter { banks & (1 << $0) != 0 })
    if m.machine != nil { m.powerOn() }
    return 0
}

/// Fits VideoNuLA in place of the Video ULA (`on` 1), or the ULA (0). A
/// machine that's on is power cycled.
@_expose(wasm, "beeb_set_video_nula")
@_cdecl("beeb_set_video_nula")
public func beeb_set_video_nula(_ handle: Int32, _ on: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    m.configuration.videoNuLA = on != 0
    if m.machine != nil { m.powerOn() }
    return 0
}
