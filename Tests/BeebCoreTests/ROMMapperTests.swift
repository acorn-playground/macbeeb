// Sideways ROMs bigger than 16K, switched by the addresses their code
// touches (b2's mappers). With synthetic images, and with the real
// Computer Concepts ROMs when they're in roms/ (not committed).

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

/// A user's ROM from roms/ at the top of the package, if it's there.
func userROM(_ name: String) -> [UInt8]? {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("roms").appendingPathComponent(name)
    return FileManager.default.contents(atPath: url.path).map { [UInt8]($0) }
}

/// An image of `size` bytes whose every 4K page is filled with its own
/// number, so a read says which page is showing.
private func pageNumbered(_ size: Int) -> [UInt8] {
    (0..<size).map { UInt8($0 >> 12) }
}

struct ROMMapperTests {
    /// The real Computer Concepts ROMs, when they're in roms/: their tests
    /// are skipped where they aren't (as on GitHub).
    static let interWord = userROM("Computer Concepts InterWord v1.02 [32k].rom")
    static let interBase = userROM("Computer Concepts InterBase v2.0A [64k].rom")

    @Test func interWordSwitchesHalves() {
        let m = BBCMicro.ROMMapper.interWord
        #expect(m.region(for: 0xBFA0, current: 0) == 1 && m.region(for: 0xBFBF, current: 0) == 1)
        #expect(m.region(for: 0x8060, current: 1) == 0 && m.region(for: 0xBFC5, current: 1) == 0)
        #expect(m.region(for: 0xBFE0, current: 0) == 1 && m.region(for: 0x8040, current: 0) == 1)
        #expect(m.region(for: 0x9000, current: 0) == nil)
        #expect(m.offset(page: 2, region: 1) == 0x6000)
    }

    @Test func spellmasterOnlySwitchesFromItsFirstPart() {
        let m = BBCMicro.ROMMapper.spellmaster
        #expect(m.region(for: 0xBF00, current: 0) == 7 && m.region(for: 0xBFC0, current: 0) == 1)
        #expect(m.region(for: 0xBF00, current: 3) == nil)
        #expect(m.region(for: 0xBFE0, current: 3) == 0)
    }

    @Test func sizesPickTheCandidates() {
        #expect(BBCMicro.ROMMapper.candidates(forSize: 14893) == [.standard])
        #expect(BBCMicro.ROMMapper.candidates(forSize: 0x8000).first == .interWord)
        #expect(BBCMicro.ROMMapper.candidates(forSize: 0x10000).first == .interBase)
        #expect(BBCMicro.ROMMapper.candidates(forSize: 0x20000).first == .spellmaster)
        #expect(BBCMicro.ROMMapper.candidates(forSize: 0x5000).isEmpty)
    }

    /// Code touching &BF80-&BFFF switches an Inter-Base ROM's quarters, only
    /// while its bank is selected; a save state keeps the quarter.
    @Test func codeSwitchesTheQuarterShowing() throws {
        var configuration = BeebROMs.configuration(for: .modelB)
        configuration.sidewaysROMs[13] = pageNumbered(0x10000)
        configuration.romMappers[13] = .interBase
        let m = BBCMicro(configuration: configuration)
        m.runUntilIdle()
        // LDA #13 : STA &FE30 : LDA &BFC0 : LDA &9000 : STA &70
        // LDA &BFA0 : LDA &A000 : STA &71 : LDA &F4 : STA &FE30 : RTS
        let code: [UInt8] = [0xA9, 13, 0x8D, 0x30, 0xFE, 0xAD, 0xC0, 0xBF, 0xAD, 0x00, 0x90, 0x85, 0x70,
                             0xAD, 0xA0, 0xBF, 0xAD, 0x00, 0xA0, 0x85, 0x71, 0xA5, 0xF4, 0x8D, 0x30, 0xFE, 0x60]
        for (i, byte) in code.enumerated() { m.poke(0x2000 + UInt16(i), byte) }
        m.type("CALL &2000\n")
        m.runUntilIdle()
        // Quarter 2's second page (9), then quarter 1's third (6).
        #expect(m.peek(0x70) == 9 && m.peek(0x71) == 6)
        #expect(m.romRegions[13] == 1)
        // BASIC reading &BFC0 in its own bank doesn't touch bank 13's.
        m.type("A%=?&BFC0\n")
        m.runUntilIdle()
        #expect(m.romRegions[13] == 1)

        let restored = BBCMicro(configuration: configuration)
        try restored.restore(m.snapshot())
        #expect(restored.romRegions[13] == 1)
        #expect(cpuRead(restored, bank: 13, 0x8000) == 4)
    }

    /// Inter-Word, the real 32K ROM, in the Master's front cartridge.
    @Test(.enabled(if: interWord != nil, "Needs InterWord v1.02 in roms/"))
    func interWordRunsFromACartridge() throws {
        let rom = try #require(Self.interWord)
        var configuration = BeebROMs.configuration(for: .master128)
        configuration.sidewaysROMs[1] = rom
        configuration.romMappers[1] = .interWord
        let m = BBCMicro(configuration: configuration)
        m.runUntilIdle()
        #expect(m.sidewaysSlots[1].header?.name == "INTER-WORD 1.02")
        m.type("*IWORD\n")
        m.run(seconds: 3)
        let screen = m.screenText().joined(separator: "\n")
        #expect(screen.contains("(C) Computer Concepts 1986") && screen.contains("Please enter choice"), "\(screen)")
    }

    /// Inter-Base, the real 64K ROM, in the Model B's socket 13.
    @Test(.enabled(if: interBase != nil, "Needs InterBase v2.0A in roms/"))
    func interBaseRunsFromASocket() throws {
        let rom = try #require(Self.interBase)
        var configuration = BeebROMs.configuration(for: .modelB)
        configuration.sidewaysROMs[13] = rom
        configuration.romMappers[13] = .interBase
        let m = BBCMicro(configuration: configuration)
        m.runUntilIdle()
        m.type("*IBASE\n")
        m.run(seconds: 4)
        let screen = m.screenText().joined(separator: "\n")
        #expect(screen.contains("(C) Computer Concepts 1987") && screen.contains("Open database"), "\(screen)")
    }
}
