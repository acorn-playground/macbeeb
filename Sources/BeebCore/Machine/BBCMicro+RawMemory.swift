// The machine's RAM as it's stored, whatever's paged in: for tools that
// read or patch a machine directly (finding where a program keeps
// something, then setting it), not for emulation.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension BBCMicro {
    /// Main RAM, then shadow RAM, ANDY and HAZEL, as offsets 0..<rawRAMSize
    /// (shadow from &8000, ANDY from &10000, HAZEL from &11000; the B's and
    /// B+'s have only some of it).
    public static var rawRAMSize: Int { ramSize }

    public func peekRAM(_ offset: Int) -> UInt8 {
        (0..<Self.ramSize).contains(offset) ? ram[offset] : 0
    }

    public func pokeRAM(_ offset: Int, _ value: UInt8) {
        guard (0..<Self.ramSize).contains(offset) else { return }
        ram[offset] = value
    }

    /// A sideways bank's byte (0 for an empty socket).
    public func peekSideways(bank: Int, _ offset: Int) -> UInt8 {
        guard (0..<16).contains(bank), (0..<0x4000).contains(offset), let storage = sidewaysStorage(bank) else { return 0 }
        return storage[offset]
    }

    /// Sets a sideways RAM bank's byte (ROM is left alone). Returns whether
    /// it's RAM.
    @discardableResult
    public func pokeSideways(bank: Int, _ offset: Int, _ value: UInt8) -> Bool {
        guard (0..<16).contains(bank), (0..<0x4000).contains(offset), isSidewaysRAM(bank),
              let storage = sidewaysStorage(bank) else { return false }
        storage[offset] = value
        return true
    }
}
