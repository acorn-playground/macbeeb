#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

// Sideways ROMs bigger than 16K. A bank shows 16K at &8000-&BFFF, so a 32K,
// 64K or 128K ROM has logic on its board (or cartridge) that watches the
// address bus while its bank is selected and switches which part of the
// image is showing when the ROM's code touches particular addresses. The
// addresses and layouts are b2's (src/beeb/src/BBCMicro_Update.inl and
// type.cpp), which follow MAME's bus/bbc/rom/pal.cpp.

extension BBCMicro {
    /// How a sideways ROM's image appears in its bank.
    public enum ROMMapper: String, Codable, Sendable, CaseIterable, Identifiable {
        /// 16K or less, all of it at once.
        case standard
        /// Computer Concepts Inter-Word (also AMX Design, the Beebug Master
        /// ROM): 32K, two 16K halves.
        case interWord
        /// Computer Concepts Inter-Base (also PMS The Publisher): 64K, four
        /// 16K quarters.
        case interBase
        /// Computer Concepts Spellmaster (also Mega3): 128K, eight 16K
        /// parts.
        case spellmaster
        /// Watford Quest Paint, ConQuest, PCB Designer: 32K, the bottom 8K
        /// fixed and the top 8K one of four.
        case questPaint
        /// The Wapping Editor: 64K, the bottom 8K fixed and the top 8K one
        /// of eight.
        case wappingEditor
        /// Watford TED: 32K, as Quest Paint, switched at other addresses.
        case ted
        /// PRES Advanced BASIC Editor Plus: 32K, two halves.
        case abePlus
        /// PRES Advanced BASIC Editor: 32K, two halves the other way round.
        case abe
        /// Acornsoft View Trilogy: 64K, four quarters.
        case viewTrilogy
        /// Instant Mini Office II: 128K.
        case miniOffice2

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .standard: "16K"
            case .interWord: "Inter-Word (32K)"
            case .interBase: "Inter-Base (64K)"
            case .spellmaster: "Spellmaster (128K)"
            case .questPaint: "Quest Paint (32K)"
            case .wappingEditor: "Wapping Editor (64K)"
            case .ted: "TED (32K)"
            case .abePlus: "ABE+ (32K)"
            case .abe: "ABE (32K)"
            case .viewTrilogy: "View Trilogy (64K)"
            case .miniOffice2: "Mini Office II (128K)"
            }
        }

        /// The image's size: at most this for a standard ROM, exactly this
        /// for the others.
        public var size: Int {
            switch self {
            case .standard: 0x4000
            case .interWord, .questPaint, .ted, .abePlus, .abe: 0x8000
            case .interBase, .wappingEditor, .viewTrilogy: 0x10000
            case .spellmaster, .miniOffice2: 0x20000
            }
        }

        /// The mappers for an image of `size` bytes, most likely first.
        public static func candidates(forSize size: Int) -> [ROMMapper] {
            if size <= 0x4000 { return [.standard] }
            return allCases.filter { $0.size == size }
        }

        /// The region an access to `address` (&8000-&BFFF) switches to, if
        /// it switches; `current` is the region showing now.
        @inline(__always)
        func region(for address: UInt16, current: UInt8) -> UInt8? {
            switch self {
            case .standard:
                return nil
            case .interWord:
                switch address & 0xFFE0 {
                case 0x8060, 0xBFC0: return 0
                case 0x8040, 0xBFA0, 0xBFE0: return 1
                default: return nil
                }
            case .interBase:
                switch address & 0xFFE0 {
                case 0xBF80: return 0
                case 0xBFA0: return 1
                case 0xBFC0: return 2
                case 0xBFE0: return 3
                default: return nil
                }
            case .spellmaster:
                // &BFE0 always goes back to 0; the others only from 0.
                if address & 0xFFE0 == 0xBFE0 { return 0 }
                guard current == 0, address & 0xFF00 == 0xBF00 else { return nil }
                return 7 - UInt8((address >> 5) & 7)
            case .questPaint:
                switch address & 0xFFE0 {
                case 0x8820: return 2
                case 0x91E0: return 1
                case 0x92C0: return 3
                case 0x9340: return 0
                default: return nil
                }
            case .wappingEditor:
                guard address & 0xFF00 == 0x9F00 else { return nil }
                return UInt8((address >> 5) & 7)
            case .ted:
                guard address & 0xFF80 == 0x9F80 else { return nil }
                return UInt8((address >> 5) & 3)
            case .abePlus, .abe:
                switch address & 0xFFFC {
                case 0xBFF8: return 0
                case 0xBFFC: return 1
                default: return nil
                }
            case .viewTrilogy:
                guard address & 0xFFF8 == 0xBFF8 else { return nil }
                return UInt8(address & 3)
            case .miniOffice2:
                guard address & 0xFFF0 == 0xA000 else { return nil }
                return UInt8(address & 0xF)
            }
        }

        /// Where 4K page `page` (0-3, for &8000-&BFFF) of the bank is in
        /// the image while `region` is showing.
        func offset(page: Int, region: UInt8) -> Int {
            let region = Int(region)
            switch self {
            case .standard:
                return page << 12
            case .interWord, .abePlus:
                return ((region & 1) * 4 + page) << 12
            case .abe:
                return ((~region & 1) * 4 + page) << 12
            case .interBase, .viewTrilogy:
                return ((region & 3) * 4 + page) << 12
            case .spellmaster:
                return ((region & 7) * 4 + page) << 12
            case .questPaint, .ted:
                return page < 2 ? page << 12 : ((region & 3) << 1 | (page & 1)) << 12
            case .wappingEditor:
                return page < 2 ? page << 12 : ((region & 7) << 1 | (page & 1)) << 12
            case .miniOffice2:
                return region & 1 != 0 ? ((region & 0xF) * 2 + (page & 1)) << 12 : ((region & 0xF) * 2 + page) << 12
            }
        }
    }
}
