// The Acorn SCSI interface (the Winchester's host adaptor) on the 1MHz bus,
// at &FC40-&FC43, with up to four hard discs behind it.
//
// A port of b2's scsi.cpp (Tom Seddon, GPLv3), itself based on BeebEm's
// Scsi.cpp by Jon Welch and Y. Tanaka (GPLv2+).
//
//   +0  data           R/W
//   +1  status         R
//   +2  select         W
//   +3  IRQ enable     W

final class AcornSCSI {
    static let driveCount = 4

    private enum Phase: UInt8 {
        case busFree, selection, command, execute, read, write, status, message
    }

    private enum Command {
        static let testUnitReady: UInt8 = 0x00
        static let requestSense: UInt8 = 0x03
        static let formatUnit: UInt8 = 0x04
        static let read: UInt8 = 0x08
        static let write: UInt8 = 0x0A
        static let translate: UInt8 = 0x0F
        static let modeSelect: UInt8 = 0x15
        static let modeSense: UInt8 = 0x1A
        static let startStopUnit: UInt8 = 0x1B
        static let writeExtended: UInt8 = 0x2A
        static let writeAndVerify: UInt8 = 0x2E
        static let verify: UInt8 = 0x2F
    }

    private enum Code {
        static let badDiskAddress: UInt8 = 0x21
        static let volumeError: UInt8 = 0x23
        static let badDriveNumber: UInt8 = 0x25
        static let unsupportedCommand: UInt8 = 0x27
    }

    /// The status register's bits.
    private enum Bit {
        static let msg: UInt8 = 0x01
        static let bsy: UInt8 = 0x02
        static let irq: UInt8 = 0x10
        static let req: UInt8 = 0x20
        static let io: UInt8 = 0x40
        static let cd: UInt8 = 0x80
    }

    var discs: [HardDisc?] = Array(repeating: nil, count: driveCount)
    /// Set while a command's running: the drive light.
    private(set) var activeDrive: Int?
    /// Whether the interface is asking for an interrupt.
    private(set) var irq = false

    private var phase = Phase.busFree
    private var code: UInt8 = 0
    private var sector = 0
    private var statusRegister: UInt8 = 0
    private var status: UInt8 = 0
    private var sel = false
    private var blocks = 0
    private var length = 0
    private var message: UInt8 = 0
    private var lun = 0
    private var next = 0
    private var lastWrite: UInt8 = 0
    private var cmd = [UInt8](repeating: 0, count: 10)
    private var buffer = [UInt8](repeating: 0, count: 0x800)
    private var offset = 0

    // MARK: Registers

    func read(_ register: Int) -> UInt8 {
        switch register & 3 {
        case 0: readData()
        case 1: peek(1)
        default: 0xFF
        }
    }

    /// What a read would return, without its effects.
    func peek(_ register: Int) -> UInt8 {
        switch register & 3 {
        case 0:
            switch phase {
            case .status: status
            case .message: message
            case .read: buffer[offset]
            default: lastWrite
            }
        // REQ always reads as set, as BeebEm and b2 have it: ADFS locks up
        // on entry otherwise.
        case 1: statusRegister | Bit.req
        default: 0xFF
        }
    }

    func write(_ register: Int, _ value: UInt8) {
        switch register & 3 {
        case 0:
            sel = true
            writeData(value)
        case 1:
            sel = true
        case 2:
            sel = false
            writeData(value)
        default:
            sel = true
            if value == 0xFF {
                statusRegister |= Bit.irq
                irq = true
                status = 0
            } else {
                statusRegister &= ~Bit.irq
                irq = false
            }
        }
    }

    // MARK: Phases

    private func readData() -> UInt8 {
        switch phase {
        case .status:
            statusRegister &= ~Bit.req
            enterMessagePhase()
            return status
        case .message:
            statusRegister &= ~Bit.req
            enterBusFreePhase()
            return message
        case .read:
            let data = buffer[offset]
            offset += 1
            length -= 1
            statusRegister &= ~Bit.req
            if length == 0 {
                blocks -= 1
                if blocks == 0 {
                    enterStatusPhase()
                    return data
                }
                guard let disc = discs[lun] else {
                    enterCheckCondition(Code.volumeError)
                    return data
                }
                disc.readSector(next, into: &buffer)
                length = 256
                offset = 0
                next += 1
            }
            return data
        case .busFree:
            return lastWrite
        default:
            enterBusFreePhase()
            return lastWrite
        }
    }

    private func writeData(_ value: UInt8) {
        lastWrite = value
        switch phase {
        case .busFree:
            if sel { enterSelectionPhase() }
        case .selection:
            if !sel { enterCommandPhase() }
        case .command:
            cmd[offset] = value
            if offset == 0 && (0x20...0x3F).contains(value) {
                length = 10
            }
            length -= 1
            offset += 1
            statusRegister &= ~Bit.req
            if length == 0 { execute() }
        case .write:
            buffer[offset] = value
            offset += 1
            length -= 1
            statusRegister &= ~Bit.req
            if length == 0 {
                guard flushBuffer() else {
                    enterCheckCondition(Code.volumeError)
                    return
                }
                blocks -= 1
                if blocks == 0 {
                    enterStatusPhase()
                    return
                }
                length = 256
                next += 1
                offset = 0
            }
        default:
            enterBusFreePhase()
        }
    }

    private func flushBuffer() -> Bool {
        switch cmd[0] {
        case Command.write, Command.writeAndVerify:
            guard let disc = drive(lun) else { return false }
            disc.writeSector(next - 1, from: buffer)
            return true
        case Command.modeSelect:
            guard let disc = drive(lun) else { return false }
            return disc.setParameters(buffer[0..<offset])
        default:
            // Write Extended isn't handled (BeebEm and b2 don't either).
            return false
        }
    }

    private func enterBusFreePhase() {
        phase = .busFree
        statusRegister = 0
        activeDrive = nil
    }

    private func enterMessagePhase() {
        phase = .message
        statusRegister |= Bit.msg | Bit.req
    }

    private func enterStatusPhase() {
        phase = .status
        statusRegister |= Bit.io | Bit.cd | Bit.req
    }

    private func enterSelectionPhase() {
        phase = .selection
        statusRegister |= Bit.bsy
    }

    private func enterCommandPhase() {
        phase = .command
        statusRegister = statusRegister & ~(Bit.io | Bit.msg) | Bit.cd
        offset = 0
        length = 6
    }

    /// A Read-phase reply of `count` bytes from the buffer.
    private func enterReadPhase(_ count: Int, request: Bool = true) {
        length = count
        offset = 0
        blocks = 1
        phase = .read
        statusRegister = statusRegister & ~Bit.cd | Bit.io
        status = UInt8(lun << 5)
        message = 0
        if request { statusRegister |= Bit.req } else { statusRegister &= ~Bit.req }
    }

    private func enterGoodStatus() {
        status = UInt8(lun << 5)
        message = 0
        enterStatusPhase()
    }

    private func enterCheckCondition(_ code: UInt8) {
        status = UInt8(lun << 5) | 2
        message = 0
        self.code = code
        enterStatusPhase()
    }

    private var lba: Int { Int(cmd[1] & 0x1F) << 16 | Int(cmd[2]) << 8 | Int(cmd[3]) }

    private func drive(_ lun: Int) -> HardDisc? {
        lun < Self.driveCount ? discs[lun] : nil
    }

    /// The command's drive, or Check Condition if there's none.
    private func commandDrive() -> HardDisc? {
        guard let disc = drive(lun) else {
            enterCheckCondition(Code.badDriveNumber)
            return nil
        }
        return disc
    }

    private func execute() {
        phase = .execute
        lun = Int(cmd[1] >> 5)
        if lun < Self.driveCount { activeDrive = lun }
        switch cmd[0] {
        case Command.testUnitReady, Command.startStopUnit:
            guard commandDrive() != nil else { return }
            enterGoodStatus()
        case Command.requestSense:
            let count = cmd[4] == 0 ? 4 : Int(cmd[4])
            for i in 0..<count { buffer[i] = 0 }
            buffer[0] = code
            if code == Code.badDiskAddress {
                buffer[1] = UInt8(truncatingIfNeeded: sector >> 16)
                buffer[2] = UInt8(truncatingIfNeeded: sector >> 8)
                buffer[3] = UInt8(truncatingIfNeeded: sector)
            }
            code = 0
            sector = 0
            enterReadPhase(count)
        case Command.formatUnit:
            guard let disc = commandDrive() else { return }
            disc.format()
            enterGoodStatus()
        case Command.read:
            guard let disc = commandDrive() else { return }
            let start = lba
            disc.readSector(start, into: &buffer)
            enterReadPhase(256)
            blocks = cmd[4] == 0 ? 256 : Int(cmd[4])
            next = start + 1
        case Command.write:
            guard commandDrive() != nil else { return }
            blocks = cmd[4] == 0 ? 256 : Int(cmd[4])
            status = UInt8(lun << 5)
            message = 0
            length = 256
            next = lba + 1
            offset = 0
            phase = .write
            statusRegister = statusRegister & ~Bit.cd | Bit.req
        case Command.translate:
            let address = lba
            buffer[0] = UInt8(address & 0xFF)
            buffer[1] = UInt8(address >> 8 & 0xFF)
            buffer[2] = UInt8(address >> 16 & 0xFF)
            buffer[3] = 0
            enterReadPhase(4, request: false)
        case Command.modeSelect:
            length = Int(cmd[4])
            blocks = 1
            status = UInt8(lun << 5)
            message = 0
            next = 0
            offset = 0
            phase = .write
            statusRegister = statusRegister & ~Bit.cd | Bit.req
        case Command.modeSense:
            guard let disc = commandDrive() else { return }
            for i in buffer.indices { buffer[i] = 0 }
            for (i, byte) in disc.parameters.enumerated() { buffer[i] = byte }
            enterReadPhase(HardDisc.parametersSize)
        case Command.verify:
            guard let disc = commandDrive() else { return }
            let address = lba
            guard disc.isValid(address) else {
                sector = address
                enterCheckCondition(Code.badDiskAddress)
                return
            }
            next = address
            enterGoodStatus()
        default:
            enterCheckCondition(Code.unsupportedCommand)
        }
    }
}
