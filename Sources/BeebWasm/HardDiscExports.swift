// The ABI's hard discs (see Exports.swift for its conventions): Winchester
// discs on the Acorn SCSI interface, as BeebEm and b2 keep them (a .dat
// image of 256-byte sectors, and the .dsc's 22 bytes of the drive's
// parameters). A host that keeps the disc somewhere takes the sectors
// written since it last asked, and stores just those.

import BeebCore
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension Limits {
    static let hardDiscBytes = 64 << 20
}

/// Attaches a hard disc as SCSI drive `drive` (0-3): `count` bytes of its
/// image, and `parametersCount` (22, or 0 for the largest drive ADFS can
/// use) of its parameters. It stays attached through power cycles and
/// restored states. A machine needn't be on.
@_expose(wasm, "beeb_attach_hard_disc")
@_cdecl("beeb_attach_hard_disc")
public func beeb_attach_hard_disc(_ handle: Int32, _ drive: Int32, _ pointer: UnsafeRawPointer?, _ count: Int32,
                                  _ parameters: UnsafeRawPointer?, _ parametersCount: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard (0..<4).contains(drive) else { return fail(.invalidArgument, "no SCSI drive \(drive)") }
    guard let image = bytes(pointer, count, limit: Limits.hardDiscBytes) else { return fail(.badData, "a hard disc image is at most 64MB") }
    guard let dsc = bytes(parameters, parametersCount, limit: HardDisc.parametersSize),
          dsc.isEmpty || dsc.count == HardDisc.parametersSize else {
        return fail(.badData, "a hard disc's parameters are 22 bytes")
    }
    m.attachHardDisc(HardDisc(image: image, parameters: dsc.isEmpty ? nil : dsc), drive: Int(drive))
    return 0
}

@_expose(wasm, "beeb_detach_hard_disc")
@_cdecl("beeb_detach_hard_disc")
public func beeb_detach_hard_disc(_ handle: Int32, _ drive: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard (0..<4).contains(drive) else { return fail(.invalidArgument, "no SCSI drive \(drive)") }
    m.attachHardDisc(nil, drive: Int(drive))
    return 0
}

/// The sectors written to a hard disc since the last call, in the result
/// buffer, lowest first: each a 4-byte little-endian sector number, then
/// its 256 bytes. Returns the buffer's length (0: none written).
@_expose(wasm, "beeb_hard_disc_take_written")
@_cdecl("beeb_hard_disc_take_written")
public func beeb_hard_disc_take_written(_ handle: Int32, _ drive: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard let disc = m.hardDiscs[Int(drive)] else { return fail(.invalidArgument, "no hard disc in SCSI drive \(drive)") }
    let written = (m.writtenSectors[Int(drive)] ?? []).sorted()
    m.writtenSectors[Int(drive)] = []
    var out: [UInt8] = []
    out.reserveCapacity(written.count * 260)
    disc.image.withUnsafeBufferPointer { image in
        for lba in written {
            out += [UInt8(lba & 0xFF), UInt8(lba >> 8 & 0xFF), UInt8(lba >> 16 & 0xFF), UInt8(lba >> 24 & 0xFF)]
            let start = lba * 256
            out += (0..<256).map { start + $0 < image.count ? image[start + $0] : 0 }
        }
    }
    result.set(out)
    return Int32(out.count)
}

/// A hard disc's whole image as it is now, in the result buffer (and with
/// `which` 1, its 22 bytes of parameters instead). Returns the length.
@_expose(wasm, "beeb_export_hard_disc")
@_cdecl("beeb_export_hard_disc")
public func beeb_export_hard_disc(_ handle: Int32, _ drive: Int32, _ which: Int32) -> Int32 {
    guard let m = lookup(handle) else { return fail(.invalidHandle, "no machine \(handle)") }
    guard let disc = m.hardDiscs[Int(drive)] else { return fail(.invalidArgument, "no hard disc in SCSI drive \(drive)") }
    if which == 1 {
        result.set(disc.parameters)
    } else {
        result.set(disc.image)
    }
    return Int32(result.count)
}
