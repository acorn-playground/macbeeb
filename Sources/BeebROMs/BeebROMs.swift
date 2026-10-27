import Foundation

/// The bundled ROM images.
public enum BeebROMs {
    public enum Image: String, CaseIterable, Sendable {
        case os12 = "os12"
        case basic2 = "basic2"
        case dfs12 = "dfs12"
        case dfs226 = "dfs226"
        case bPlusMOS = "bplus-mos"
        case tube110 = "tube110"
        case z80121 = "z80-121"
        case master512BIOS = "master512-bios"
        case armEval100 = "armeval-100"
        case masterTurboParasite = "master-turbo-parasite"
        case watfordDDFS153 = "watford-ddfs153"
        case watfordDDFS154T = "watford-ddfs154t"
        case opusDDOS345 = "opus-ddos345"
        case mos510 = "mos510-mos"
        case mos510Utils = "mos510-utils"
        case mos510BASIC4 = "mos510-basic4"
        case mos510ADFS = "mos510-adfs"
        case mos320 = "mos320-mos"
        case mos320Terminal = "mos320-terminal"
        case mos320View = "mos320-view"
        case mos320ADFS = "mos320-adfs"
        case mos320BASIC4 = "mos320-basic4"
        case mos320Edit = "mos320-edit"
        case mos320ViewSheet = "mos320-viewsht"
        case mos320DFS = "mos320-dfs"
        /// Expansion boards' controller ROMs (see Firmware).
        case watford32KRAM240 = "watford-32kram-240"
        case ariesB32100 = "aries-b32-100"
        case dnfs = "dnfs"
        case anfs425 = "anfs425"
    }

    /// The resource bundle. In an app it's in Contents/Resources (SwiftPM's
    /// Bundle.module only looks next to the executable, which codesign
    /// won't accept); elsewhere, Bundle.module finds it.
    static let bundle: Bundle = {
        let name = "macbeeb_BeebROMs.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    /// The bundled discs: the co-processors' system discs, and the rest of
    /// the Master 512's.
    public enum BundledDisc: String, CaseIterable, Sendable {
        /// Acorn CP/M 2.2 (BIOS 1.20) and its utilities, for the Z80.
        case cpm = "cpm-utilities.dsd"
        /// DOS Plus 1.2's boot disc, for the Master 512.
        case dosPlus = "dosplus-boot.adl"
        /// The Master 512's GEM discs (GEM itself, its applications and
        /// data) and its miscellaneous one, in its 800K DOS format.
        case gemApplications = "gem-applications.img"
        case gemData = "gem-data.img"
        case master512Miscellaneous = "master512-miscellaneous.img"
        /// Acorn's Econet Level 1 file server (FS), with the printer server
        /// (PS), NETMON, NOTIFY, REMOTE, VIEW and the protection utilities.
        case econetLevel1 = "econet-level1.ssd"
        /// The Level 2 file server and its disc manager (needs a 6502
        /// Second Processor).
        case econetLevel2 = "econet-level2.ssd"

        /// The disc the co-processor boots from, if it needs one.
        public static func system(for coprocessor: BBCMicro.Coprocessor) -> BundledDisc? {
            switch coprocessor {
            case .z80: .cpm
            case .master512: .dosPlus
            case .mos6502, .arm, .masterTurbo: nil
            }
        }

        public var displayName: String {
            switch self {
            case .cpm: "CP/M 2.2 System and Utilities (Z80)"
            case .dosPlus: "DOS Plus 1.2 Boot (Master 512, disc 1)"
            case .gemApplications: "GEM Applications (Master 512, disc 2)"
            case .gemData: "GEM Data (Master 512, disc 3)"
            case .master512Miscellaneous: "Miscellaneous (Master 512, disc 4)"
            case .econetLevel1: "Econet Level 1 File and Printer Server"
            case .econetLevel2: "Econet Level 2 File Server"
            }
        }

        /// Its name for an agent: the file name without the extension.
        public var shortName: String { (rawValue as NSString).deletingPathExtension }

        public var format: Disc.ImageFormat { Disc.ImageFormat(path: rawValue)! }

        public var data: [UInt8] {
            guard let url = bundle.url(forResource: rawValue, withExtension: nil, subdirectory: "Discs"),
                  let data = try? Data(contentsOf: url) else {
                preconditionFailure("missing bundled disc \(rawValue)")
            }
            return [UInt8](data)
        }
    }

    /// The bundled SCSI hard discs, kept sparse (see
    /// scripts/sparse-hard-disc.py): Mark Moxon's Elite over Econet Level 3
    /// file server discs.
    public enum BundledHardDisc: String, CaseIterable, Sendable {
        /// Elite over Econet with the flicker-free ship drawing.
        case eliteOverEconetFlickerFree = "elite-over-econet-flicker-free.mbhd"
        /// Elite over Econet as the original game drew its ships.
        case eliteOverEconet = "elite-over-econet.mbhd"

        public var displayName: String {
            switch self {
            case .eliteOverEconetFlickerFree: "Elite over Econet Level 3 File Server (flicker-free)"
            case .eliteOverEconet: "Elite over Econet Level 3 File Server"
            }
        }

        /// The disc as BeebEm keeps it: the .dat's sectors and the .dsc's
        /// parameters.
        public var contents: (image: [UInt8], parameters: [UInt8]) {
            guard let url = bundle.url(forResource: rawValue, withExtension: nil, subdirectory: "Discs"),
                  let data = try? Data(contentsOf: url), let contents = Self.unpack([UInt8](data)) else {
                preconditionFailure("missing bundled hard disc \(rawValue)")
            }
            return contents
        }

        /// "MBHD", the 22 parameter bytes, the sector count, then each
        /// sector that isn't all zeros: its number and its 256 bytes.
        static func unpack(_ bytes: [UInt8]) -> (image: [UInt8], parameters: [UInt8])? {
            func word(_ at: Int) -> Int {
                Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
            }
            guard bytes.count >= 30, bytes.prefix(4).elementsEqual("MBHD".utf8) else { return nil }
            let parameters = Array(bytes[4..<26])
            let sectors = word(26)
            var image = [UInt8](repeating: 0, count: sectors * 256)
            var at = 30
            while at + 260 <= bytes.count {
                let lba = word(at)
                guard lba < sectors else { return nil }
                image.replaceSubrange(lba * 256..<lba * 256 + 256, with: bytes[at + 4..<at + 260])
                at += 260
            }
            return at == bytes.count ? (image, parameters) : nil
        }
    }

    /// The disc drives' noises for `model`: 3.5" drives on the Compact,
    /// 5.25" on the others. Nil if the samples can't be read.
    public static func discDriveSounds(for model: BBCMicro.Model) -> DiscDriveSounds? {
        let drive = model == .masterCompact ? "35" : "525"
        let names: [DiscDriveSounds.Sound: String] = [
            .spinStartLoaded: "spin_start_loaded", .spinStartEmpty: "spin_start_empty",
            .spinLoaded: "spin_loaded", .spinEmpty: "spin_empty", .spinEnd: "spin_end",
            .step: "step_1_1", .seek2ms: "seek_2ms", .seek6ms: "seek_6ms", .seek12ms: "seek_12ms", .seek20ms: "seek_20ms",
        ]
        var rate = 0.0
        var samples: [[Float]] = []
        for sound in DiscDriveSounds.Sound.allCases {
            guard let url = bundle.url(forResource: "\(drive)_\(names[sound]!)", withExtension: "wav", subdirectory: "Sounds"),
                  let data = try? Data(contentsOf: url),
                  let wav = DiscDriveSounds.decodeWAV([UInt8](data)),
                  rate == 0 || wav.rate == rate else { return nil }
            rate = wav.rate
            samples.append(wav.samples)
        }
        return DiscDriveSounds(rate: rate, samples: samples)
    }

    public static func data(_ image: Image) -> [UInt8] {
        guard let url = bundle.url(forResource: image.rawValue, withExtension: "rom", subdirectory: "ROMs"),
              let data = try? Data(contentsOf: url) else {
            preconditionFailure("missing bundled ROM \(image.rawValue)")
        }
        return [UInt8](data)
    }
}

import BeebCore

/// What's in a ROM socket, in place of its standard ROM.
public enum SocketImage: Sendable, Equatable {
    case empty
    case rom([UInt8], BBCMicro.ROMMapper)
}

extension BeebROMs {
    /// A standard machine with the bundled ROMs:
    ///
    /// - Model B: OS 1.20, BASIC 2 (bank 15), DFS 1.20 (bank 14).
    /// - B+ 128K: the B+ MOS, BASIC 2 (bank 15), DFS 2.26 (bank 14), as b2;
    ///   sideways RAM in 0, 1, 12 and 13.
    /// - Master 128: MOS 3.20 and its ROMs in banks 9-15, as b2; sideways
    ///   RAM in 4-7.
    ///
    /// - Master Compact: MOS 5.10, Utils (bank 15), BASIC 4 (14), ADFS (13),
    ///   as b2; sideways RAM in 4-7. It boots ADFS (no DFS).
    ///
    /// With `secondProcessor`, a 6502 Second Processor (Tube OS 1.10) is
    /// fitted (not on the Compact, which has no Tube), or the `coprocessor`
    /// given: the Z80 (client ROM 1.21), the Master Turbo's 65C102 (its
    /// Tube OS 1.20; on the Master 128) or the ARM Evaluation System
    /// (supervisor ROM 1.00).
    ///
    /// The Z80 and the Master 512 start with their system disc in drive 0
    /// (CP/M, DOS Plus), so they boot, unless `systemDisc` is false.
    ///
    /// On the Model B, `discInterface` picks the disc controller and its
    /// filing system (in bank 14), and `expansions` the memory board.
    /// `sidewaysImages` are put in sideways RAM banks at power on.
    ///
    /// `socketImages` are what the user has put in the sockets, by the
    /// socket's standard bank number (an Aries board renumbers them as it
    /// does the rest), in place of the standard ROMs; the Econet's ROM and
    /// a board's controller ROM still take their sockets. `addedRAMBanks`
    /// are sideways RAM (a Master's RAM cartridge), and `removedRAMBanks`
    /// aren't (the Master's links making banks 4-7 ROM sockets).
    public static func configuration(for model: BBCMicro.Model, secondProcessor: Bool = false,
                                     coprocessor: BBCMicro.Coprocessor = .mos6502,
                                     discInterface: BBCMicro.DiscInterface = .intel8271,
                                     systemDisc: Bool = true,
                                     expansions: BBCMicro.Expansions = .none,
                                     sidewaysImages: [Int: [UInt8]] = [:],
                                     controllerROM: [UInt8]? = nil,
                                     econetStation: Int? = nil,
                                     socketImages: [Int: SocketImage] = [:],
                                     addedRAMBanks: Set<Int> = [],
                                     removedRAMBanks: Set<Int> = []) -> BBCMicro.Configuration {
        var configuration = standardConfiguration(for: model)
        configuration.coprocessor = coprocessor
        configuration.sidewaysRAMBanks.formUnion(addedRAMBanks)
        configuration.sidewaysRAMBanks.subtract(removedRAMBanks)
        if model == .modelB {
            configuration.expansions = expansions
            configuration.discInterface = discInterface
            configuration.sidewaysROMs[14] = switch discInterface {
            case .intel8271: data(.dfs12)
            case .acorn1770: data(.dfs226)
            case .watfordDDB2: data(.watfordDDFS153)
            case .watfordDDB3: data(.watfordDDFS154T)
            case .opus: data(.opusDDOS345)
            }
        }
        for (bank, image) in socketImages where (0..<16).contains(bank) {
            switch image {
            case .empty:
                configuration.sidewaysROMs[bank] = nil
                configuration.romMappers[bank] = nil
            case .rom(let data, let mapper):
                configuration.sidewaysROMs[bank] = data
                configuration.romMappers[bank] = mapper == .standard ? nil : mapper
            }
        }
        // Econet: the network filing system's ROM. The B's DNFS has DFS
        // 1.20 in it, so it takes the 8271 DFS's place; with another disc
        // interface it goes in bank 13. The Masters' ANFS goes in bank 8.
        if let econetStation, model != .modelA {
            configuration.econetStation = econetStation
            switch model {
            case .modelB:
                let bank = discInterface == .intel8271 ? 14 : 13
                configuration.sidewaysROMs[bank] = data(.dnfs)
                configuration.romMappers[bank] = nil
            case .master128, .masterCompact:
                configuration.sidewaysROMs[8] = data(.anfs425)
                configuration.romMappers[8] = nil
            case .modelA, .bPlus:
                break
            }
        }
        if secondProcessor && coprocessor.fits(model) {
            let rom: Image = switch coprocessor {
            case .mos6502: .tube110
            case .z80: .z80121
            case .master512: .master512BIOS
            case .arm: .armEval100
            case .masterTurbo: .masterTurboParasite
            }
            configuration.secondProcessorROM = data(rom)
            if systemDisc, let disc = BundledDisc.system(for: coprocessor) {
                configuration.startupDisc = .init(name: disc.rawValue, image: disc.data, format: disc.format)
            }
        }
        // The Aries boards renumber the four ROM sockets. The B32 alone: the
        // motherboard's sockets, 12-15 from left to right, become 12, 9,
        // 10, 11. With the B12, its manual says to move them to its
        // sockets 9-12 in the same order. Either way BASIC (the rightmost)
        // is still the highest-numbered language and the DFS next to it.
        if configuration.fittedExpansions.board.isAries {
            let mapping: [Int: Int] = configuration.fittedExpansions.board == .ariesB32B12
                ? [12: 9, 13: 10, 14: 11, 15: 12] : [12: 12, 13: 9, 14: 10, 15: 11]
            var renumbered: [Int: [UInt8]] = [:]
            for (bank, image) in configuration.sidewaysROMs {
                renumbered[mapping[bank] ?? bank] = image
            }
            configuration.sidewaysROMs = renumbered
            configuration.romMappers = Dictionary(uniqueKeysWithValues: configuration.romMappers.map { (mapping[$0.key] ?? $0.key, $0.value) })
        }
        // A board's controller ROM: the bundled one, or the user's own.
        if let bank = configuration.fittedExpansions.controllerROMBank,
           let firmware = Firmware.standard(for: configuration.fittedExpansions.board) {
            configuration.sidewaysROMs[bank] = controllerROM ?? firmware.bundledData
            configuration.romMappers[bank] = nil
        }
        // Only into RAM, and never over a ROM.
        let ramBanks = configuration.sidewaysRAMBanks.union(configuration.fittedExpansions.sidewaysRAMBanks)
        for (bank, image) in sidewaysImages where ramBanks.contains(bank) && image.count <= 0x4000 {
            configuration.sidewaysROMs[bank] = image
        }
        // RAM is RAM: no ROM, or mapper, under it.
        for bank in ramBanks {
            configuration.romMappers[bank] = nil
            if sidewaysImages[bank] == nil { configuration.sidewaysROMs[bank] = nil }
        }
        return configuration
    }

    private static func standardConfiguration(for model: BBCMicro.Model) -> BBCMicro.Configuration {
        switch model {
        case .modelA:
            return BBCMicro.Configuration(model: .modelA, os: data(.os12), sidewaysROMs: [15: data(.basic2)])
        case .modelB:
            return BBCMicro.Configuration(os: data(.os12), sidewaysROMs: [15: data(.basic2), 14: data(.dfs12)])
        case .bPlus:
            return BBCMicro.Configuration(model: .bPlus, os: data(.bPlusMOS),
                                          sidewaysROMs: [15: data(.basic2), 14: data(.dfs226)])
        case .masterCompact:
            return BBCMicro.Configuration(model: .masterCompact, os: data(.mos510), sidewaysROMs: [
                15: data(.mos510Utils),
                14: data(.mos510BASIC4),
                13: data(.mos510ADFS),
            ])
        case .master128:
            return BBCMicro.Configuration(model: .master128, os: data(.mos320), sidewaysROMs: [
                15: data(.mos320Terminal),
                14: data(.mos320View),
                13: data(.mos320ADFS),
                12: data(.mos320BASIC4),
                11: data(.mos320Edit),
                10: data(.mos320ViewSheet),
                9: data(.mos320DFS),
            ])
        }
    }
}
