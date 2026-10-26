// The devices' state as labelled rows, for the debugger's hardware views.

public struct HardwareSection: Sendable, Equatable, Identifiable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
    }

    public var name: String
    public var rows: [Row]
    public var id: String { name }

    init(_ name: String, _ rows: [(String, String)]) {
        self.name = name
        self.rows = rows.map { Row(label: $0.0, value: $0.1) }
    }
}

private func hex(_ value: some BinaryInteger, _ digits: Int = 2) -> String {
    let text = String(value, radix: 16, uppercase: true)
    return "&" + String(repeating: "0", count: max(0, digits - text.count)) + text
}

private func bits(_ value: UInt8) -> String {
    (0..<8).reversed().map { value & 1 << $0 != 0 ? "1" : "0" }.joined()
}

extension BBCMicro {
    /// Every device's state.
    public var hardwareState: [HardwareSection] {
        var sections = [
            Self.viaState("System VIA", systemVIA),
            Self.viaState("User VIA", userVIA),
            crtcState,
            videoULAState,
            soundState,
            pagingState,
            discState,
            serialState,
            HardwareSection("ADC (uPD7002)", (0..<4).map { ("Channel \($0)", "\(adc.channels[$0])") }
                + [("Status", hex(adc.peek(0)))]),
        ]
        if secondProcessor != nil {
            sections.append(tubeState)
        }
        if let expansion = expansionState {
            sections.append(expansion)
        }
        if model == .masterCompact {
            sections.append(HardwareSection("Settings EEPROM (PCD8572)", [
                ("Contents", eeprom.contents.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " ") + " …"),
                ("Joystick", "%" + String(digitalJoystick, radix: 2)),
            ]))
        }
        if model == .master128 {
            sections.append(HardwareSection("Clock (MC146818)", [
                ("Address", hex(rtc.address)),
                ("CMOS RAM", rtc.ram.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " ") + " …"),
            ]))
        }
        return sections
    }

    static func viaState(_ name: String, _ via: VIA6522) -> HardwareSection {
        let interrupts = ["CA2", "CA1", "SR", "CB2", "CB1", "T2", "T1"]
        func flagNames(_ value: UInt8) -> String {
            let set = (0..<7).filter { value & 1 << $0 != 0 }.map { interrupts[$0] }
            return set.isEmpty ? "—" : set.joined(separator: " ")
        }
        return HardwareSection(name, [
            ("ORA / DDRA", "\(hex(via.a.or)) / \(hex(via.a.ddr))"),
            ("Port A pins", "\(hex(via.a.p)) %\(bits(via.a.p))"),
            ("ORB / DDRB", "\(hex(via.b.or)) / \(hex(via.b.ddr))"),
            ("Port B pins", "\(hex(via.b.p)) %\(bits(via.b.p))"),
            ("CA1 CA2 CB1 CB2", "\(via.a.c1) \(via.a.c2) \(via.b.c1) \(via.b.c2)"),
            ("T1 counter", "\(hex(via.t1, 4)) (latch \(hex(UInt16(via.t1lh) << 8 | UInt16(via.t1ll), 4)))"),
            ("T2 counter", "\(hex(via.t2, 4)) (latch low \(hex(via.t2ll)))"),
            ("SR", hex(via.sr)),
            ("ACR", "\(hex(via.acr)) %\(bits(via.acr))"),
            ("PCR", "\(hex(via.pcr)) %\(bits(via.pcr))"),
            ("IFR", "\(hex(via.ifr)) \(flagNames(via.ifr))"),
            ("IER", "\(hex(via.ier | 0x80)) \(flagNames(via.ier))"),
        ])
    }

    var crtcState: HardwareSection {
        let names = ["Horizontal total", "Horizontal displayed", "H sync position", "Sync widths",
                     "Vertical total", "V total adjust", "Vertical displayed", "V sync position",
                     "Interlace & skew", "Max scan line", "Cursor start", "Cursor end",
                     "Start address H", "Start address L", "Cursor H", "Cursor L", "Light pen H", "Light pen L"]
        var rows: [(String, String)] = (0..<18).map { ("R\($0) \(names[$0])", hex(crtc.registers[$0])) }
        let start = UInt16(crtc.registers[12]) << 8 | UInt16(crtc.registers[13])
        rows.insert(contentsOf: [
            ("Beam", "column \(crtc.column), row \(crtc.row), raster \(crtc.raster)"),
            ("Address", "\(hex(crtc.charAddress, 4)) (line \(hex(crtc.lineAddress, 4)), start \(hex(start, 4)))"),
            ("Display / syncs", "\(crtcLastOutput.display ? "display" : "border")\(crtcLastOutput.hsync ? ", hsync" : "")\(crtcLastOutput.vsync ? ", vsync" : "")"),
            ("Selected register", "R\(crtc.address)"),
        ], at: 0)
        return HardwareSection("CRTC (6845)", rows)
    }

    var videoULAState: HardwareSection {
        let rates = ["2MHz", "4MHz", "8MHz", "16MHz"]
        let colours = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        var rows: [(String, String)] = [
            ("Control", "\(hex(videoULA.control)) %\(bits(videoULA.control))"),
            ("Mode", "\(videoULA.teletext ? "teletext" : "bitmap"), \(rates[Int(videoULA.lineWidth)]) pixels, \(videoULA.fast6845 ? "2MHz" : "1MHz") CRTC\(videoULA.flash ? ", flash" : "")"),
            ("Screen RAM", videoRAMOffset != 0 ? "shadow" : "main"),
        ]
        // The palette holds the physical colour (the OS writes it EOR 7 and
        // the ULA inverts it back).
        for logical in 0..<16 {
            let physical = videoULA.palette[logical]
            let name = (physical & 8 != 0 ? "flashing " : "") + colours[Int(physical & 7)]
            rows.append(("Palette \(logical)", "\(physical) (\(name))"))
        }
        if let n = nula {
            rows.append(("VideoNuLA", n.disableA1 ? "fitted, registers disabled (function 5) until power off" : "fitted: &FE22 control, &FE23 palette"))
            rows.append(("NuLA palette mode", n.directPalette ? "direct (logical colours)" : "through the ULA palette"))
            rows.append(("NuLA offset / blanking", "\(n.scrollOffset) / \(n.blankingSize)"))
            rows.append(("NuLA attribute mode", "\(n.attributeMode)\(n.textAttributeMode ? ", text attributes" : "")"))
            rows.append(("NuLA palette write", n.paletteWritePending ? "half done (first byte \(hex(n.paletteWriteBuffer)))" : "ready"))
            for i in 0..<16 {
                rows.append(("NuLA colour \(i)", String(format: "&%03X ", n.outputPalette[i]) + n.rgb888(i) + (n.flash[i] ? ", flashes" : "")))
            }
        }
        return HardwareSection(nula == nil ? "Video ULA" : "Video ULA (VideoNuLA)", rows)
    }

    var soundState: HardwareSection {
        var rows: [(String, String)] = (0..<3).map { i in
            let ch = soundChip.channels[i]
            let hz = ch.frequency == 0 ? 0 : 4_000_000 / (32 * Int(ch.frequency))
            return ("Tone \(i)", "period \(ch.frequency) (\(hz)Hz), volume \(ch.volume)")
        }
        let noise = soundChip.channels[3]
        let rate = ["high", "medium", "low", "tone 2"][Int(noise.frequency & 3)]
        rows.append(("Noise", "\(noise.frequency & 4 != 0 ? "white" : "periodic"), \(rate), volume \(noise.volume)"))
        rows.append(("Latched register", "\(soundChip.register)"))
        return HardwareSection("Sound (SN76489)", rows)
    }

    var pagingState: HardwareSection {
        var rows: [(String, String)] = [
            ("ROMSEL", "\(hex(romsel)) (bank \(String(romsel & 0x0F, radix: 16, uppercase: true)) at &8000)"),
            ("Addressable latch", "\(hex(addressableLatch)) %\(bits(addressableLatch))"),
        ]
        switch model {
        case .modelA, .modelB:
            break
        case .bPlus:
            rows.append(("Paged RAM at &8000", romsel & 0x80 != 0 ? "yes" : "no"))
            rows.append(("ACCCON", "\(hex(acccon)) (shadow \(acccon & 0x80 != 0 ? "on" : "off"))"))
        case .master128, .masterCompact:
            let flags = ["D display shadow", "E VDU shadow", "X shadow", "Y HAZEL", "ITU", "IFJ", "TST", "IRR"]
            let set = (0..<8).filter { acccon & 1 << $0 != 0 }.map { flags[$0] }
            rows.append(("ANDY at &8000", romsel & 0x80 != 0 ? "yes" : "no"))
            rows.append(("ACCCON", "\(hex(acccon)) \(set.isEmpty ? "" : set.joined(separator: ", "))"))
        }
        if model != .modelB {
            rows.append(("Current instruction", pageTable == 16 ? "in the VDU area (sees shadow RAM)" : "outside the VDU area"))
        }
        return HardwareSection("Memory paging", rows)
    }

    var discState: HardwareSection {
        var rows: [(String, String)] = []
        if let fdc = intel8271 {
            rows.append(("Controller", "Intel 8271"))
            rows.append(("Status / result", "\(hex(fdc.peek(0))) / \(hex(fdc.peek(1)))"))
            rows.append(("NMI", fdc.nmi ? "asserted" : "—"))
        } else if let fdc = wd1770 {
            rows.append(("Controller", "WD1770"))
            rows.append(("Status", "\(hex(fdc.peek(0))) %\(bits(fdc.peek(0)))"))
            rows.append(("Track / sector / data", "\(fdc.peek(1)) / \(fdc.peek(2)) / \(hex(fdc.peek(3)))"))
            rows.append(("INTRQ / DRQ", "\(fdc.intrq ? "1" : "0") / \(fdc.drq ? "1" : "0")"))
            rows.append(("Selected", fdc.selectedDrive.map { "drive \($0), \(fdc.isSideUpper ? "upper" : "lower") side, \(fdc.isDoubleDensity ? "double" : "single") density" } ?? "no drive"))
        }
        for drive in drives {
            rows.append(("Drive \(drive.id)", "\(drive.disc == nil ? "empty" : "disc in"), track \(drive.track), motor \(drive.spinning ? "on" : "off")"))
        }
        return HardwareSection("Discs", rows)
    }

    var serialState: HardwareSection {
        let acia = serial.acia
        return HardwareSection("Serial and tape", [
            ("ACIA status / control", "\(hex(acia.status)) / \(hex(acia.control))"),
            ("Serial ULA", "\(hex(serial.control)): \(serial.rs423Selected ? "RS423" : "cassette"), motor \(serial.motorOn ? "on" : "off")"),
            ("Tape", tape.map { String(format: "%.1fs of %.1fs", $0.elapsed, $0.duration) } ?? "none"),
        ])
    }

    /// The Model B's expansion board, if one's fitted.
    var expansionState: HardwareSection? {
        let expansions = configuration.fittedExpansions
        guard !expansions.isStock else { return nil }
        var rows = [("Board", expansions.board.displayName),
                    ("Sideways RAM module", expansions.sidewaysRAM == .none ? "none"
                        : "\(expansions.sidewaysRAM.displayName), banks \(expansions.moduleBanks.map(String.init).joined(separator: " and "))"),
                    ("ROMSEL (\(ariesFitted ? "read" : "read and write"))", "\(hex(romsel)) (bank \(romsel & 0x0F))")]
        if watfordFitted {
            rows.append(("Watford latch", watfordMapping.description))
            rows.append(("Writes to &FFFD", "\(watfordFFFDWrites) (no known effect)"))
            rows.append(("Video reads", "main RAM, always"))
        }
        if ariesFitted {
            rows.append(("Shadow switches", aries.shadowAllocation))
            rows.append(("Shadow now (&FE3E/&FE3F)", aries.shadow ? "on: the CPU sees shadow RAM" : "off: the CPU sees main RAM"))
            rows.append(("Writes (&FE32)", "\(hex(aries.ramsel)): \(aries.writeTarget)"))
            rows.append(("Start-up link", ariesStartUpLink ? "fitted" : "removed"))
            rows.append(("ROM's state (&27F)", hex(peek(0x27F))))
            rows.append(("Video reads", "main RAM, always"))
        }
        if !controllerWrites.isEmpty {
            rows.append(("Last register writes", controllerWrites.suffix(6).map { "\(hex($0.address, 4))=\(hex($0.value))" }.joined(separator: " ")))
        }
        if let bank = expansions.controllerROMBank {
            rows.append(("Controller ROM", sidewaysSlots[bank].header.map { "\($0.name), bank \(bank)" } ?? "missing (bank \(bank))"))
        }
        for bank in expansions.sidewaysRAMBanks {
            let slot = sidewaysSlots[bank]
            rows.append(("Bank \(bank) (RAM)", slot.header.map { "ROM image: \($0.name)" } ?? "no ROM image"))
        }
        return HardwareSection("Expansions", rows)
    }

    var tubeState: HardwareSection {
        let t = tube
        let flags = ["Q", "I", "J", "M", "V", "P", "T", "S"]
        let set = (0..<8).filter { t.status & 1 << $0 != 0 }.map { flags[$0] }.joined()
        return HardwareSection("Tube", [
            ("Status", "\(hex(t.status)) \(set)"),
            ("Host side (R0-R7)", (0..<8).map { String(format: "%02X", t.hostPeek($0)) }.joined(separator: " ")),
            ("Parasite side", (0..<8).map { String(format: "%02X", t.parasitePeek($0)) }.joined(separator: " ")),
            ("Host IRQ / parasite IRQ / NMI", "\(t.hostIRQ ? "1" : "0") / \(t.parasiteIRQ ? "1" : "0") / \(t.parasiteNMI ? "1" : "0")"),
            ("Second processor", secondProcessor?.bootMode == true ? "boot mode (ROM at &F000)" : "running from RAM"),
        ])
    }
}
