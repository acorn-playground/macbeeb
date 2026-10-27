// A SCSI hard disc, as BeebEm and b2 keep one: a .dat file of 256-byte
// sectors in LBA order, and a 22-byte .dsc file of the drive's parameters
// (what Mode Sense returns). The image may be shorter than the drive:
// sectors past its end read as zeros.
//
// See http://www.cowsarenotpurple.co.uk/bbccomputer/native/adfs.html

/// A hard disc on the Acorn SCSI interface. Its sectors are kept in memory;
/// `onSectorWritten` hears of each write, to keep the file up to date.
public final class HardDisc: @unchecked Sendable {
    /// BBC hard discs have 33 sectors a track.
    public static let sectorsPerTrack = 33
    public static let parametersSize = 22

    public private(set) var image: [UInt8]
    public private(set) var parameters: [UInt8]
    /// Told the sector number and its 256 bytes, after the BBC writes it.
    public var onSectorWritten: ((Int, ArraySlice<UInt8>) -> Void)?
    /// Told the new parameters, after Mode Select sets them.
    public var onParametersWritten: (([UInt8]) -> Void)?
    /// Told when Format Unit empties the drive.
    public var onFormatted: (() -> Void)?

    /// `parameters`: the .dsc file's 22 bytes, or nil for b2's default (the
    /// largest drive 8-bit ADFS can use).
    public init(image: [UInt8], parameters: [UInt8]?) {
        self.image = image
        if let parameters, parameters.count == Self.parametersSize {
            self.parameters = parameters
        } else {
            var dsc = [UInt8](repeating: 0, count: Self.parametersSize)
            dsc[3] = 0x80
            dsc[10] = 1
            dsc[12] = 1
            dsc[13] = UInt8(6356 >> 8)
            dsc[14] = UInt8(6356 & 0xFF)
            dsc[15] = 10
            dsc[17] = 0x80
            dsc[19] = 0x80
            self.parameters = dsc
        }
    }

    public var heads: Int { Int(parameters[15]) }
    public var cylinders: Int { Int(parameters[13]) << 8 | Int(parameters[14]) }
    public var sectorCount: Int { heads * cylinders * Self.sectorsPerTrack }

    func isValid(_ lba: Int) -> Bool { lba < sectorCount }

    func readSector(_ lba: Int, into buffer: inout [UInt8]) {
        let start = lba * 256
        for i in 0..<256 {
            buffer[i] = start + i < image.count ? image[start + i] : 0
        }
    }

    func writeSector(_ lba: Int, from buffer: [UInt8]) {
        let start = lba * 256
        if image.count < start + 256 {
            image.append(contentsOf: [UInt8](repeating: 0, count: start + 256 - image.count))
        }
        image.replaceSubrange(start..<start + 256, with: buffer[0..<256])
        onSectorWritten?(lba, image[start..<start + 256])
    }

    func setParameters(_ buffer: ArraySlice<UInt8>) -> Bool {
        guard buffer.count >= Self.parametersSize else { return false }
        parameters = Array(buffer.prefix(Self.parametersSize))
        onParametersWritten?(parameters)
        return true
    }

    /// Format Unit: the drive's emptied (as b2 truncates its file).
    func format() {
        image = []
        onFormatted?()
    }
}
