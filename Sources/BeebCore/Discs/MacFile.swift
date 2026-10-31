#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// A Mac file or folder on its way onto a disc, with its BBC name and
/// addresses.
public struct MacFile: Sendable {
    public var name: String
    public var loadAddress: UInt32 = 0
    public var executionAddress: UInt32 = 0
    public var locked = false
    /// nil for a folder.
    public var contents: [UInt8]?
    public var children: [MacFile] = []

    private init(name: String) {
        self.name = name
    }

    /// Reads `url`, and its .inf if it has one (NAME.inf or, for NAME.ext,
    /// NAME.inf). Without one, a .bas file of text is tokenised as BASIC
    /// would, and a .txt file's lines end in CRs, for *TYPE and *EXEC.
    /// Nil for .inf files themselves, and for folders on DFS.
    public static func read(_ url: URL, adfs: Bool) throws -> MacFile? {
        #if os(WASI)
        // (Reading the Mac's files needs Foundation's URL resources.)
        throw CocoaError(.featureUnsupported)
        #else
        let ext = url.pathExtension.lowercased()
        guard ext != "inf" else { return nil }
        let macName = url.lastPathComponent
        if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard adfs else { return nil }
            var folder = MacFile(name: bbcName(macName, adfs: true))
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                         options: .skipsHiddenFiles)) ?? []
            folder.children = try contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { try read($0, adfs: true) }
            return folder
        }
        var bytes = [UInt8](try Data(contentsOf: url))
        let infURLs = [url.appendingPathExtension("inf"), url.deletingPathExtension().appendingPathExtension("inf")]
        if let infURL = infURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let text = try? String(contentsOf: infURL, encoding: .isoLatin1), let inf = InfFile(text: text) {
            var file = MacFile(name: adfs ? String(inf.name.split(separator: ".").last ?? Substring(inf.name)) : inf.name)
            file.loadAddress = inf.loadAddress
            file.executionAddress = inf.executionAddress
            file.locked = inf.locked
            file.contents = bytes
            return file
        }
        var file = MacFile(name: bbcName(macName, adfs: adfs))
        if ext == "bas", !BBCBasic.isProgram(bytes) {
            bytes = try BBCBasic.tokenise(String(decoding: bytes, as: UTF8.self))
            // As SAVE leaves them on a Model B: PAGE, and BASIC's entry.
            file.loadAddress = 0xFFFF_1900
            file.executionAddress = 0xFFFF_8023
        } else if ext == "txt" {
            bytes = bytes.replacing([0x0D, 0x0A], with: [0x0D]).map { $0 == 0x0A ? 0x0D : $0 }
        }
        file.contents = bytes
        return file
        #endif
    }

    /// A Mac file name as a BBC one: "/" back from ":", a DFS directory
    /// kept ("W.DATA"), any other extension dropped, cut to fit.
    public static func bbcName(_ macName: String, adfs: Bool) -> String {
        var name = InfFile.bbcName(macName)
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        if !adfs, parts.count == 2, parts[0].count == 1 {
            return String(parts[0]) + "." + String(parts[1].prefix(DFSDisc.maxNameLength))
        }
        if parts.count > 1 {
            name = parts.dropLast().joined(separator: ".")
        }
        name = name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ".", with: "_")
        return String(name.prefix(adfs ? ADFSDisc.maxNameLength : DFSDisc.maxNameLength))
    }

    public func add(to volume: inout DiscVolume, at location: DiscVolume.Location) throws {
        if let contents {
            try volume.save(at: location, name: name, loadAddress: loadAddress, executionAddress: executionAddress,
                            contents: contents, locked: locked)
            return
        }
        // A folder: an ADFS directory (or the one there already).
        let existing = try volume.items(at: location).first { $0.id == name.uppercased() }
        if existing == nil {
            try volume.createDirectory(at: location, name: name)
        }
        guard let directory = try volume.items(at: location).first(where: { $0.id == name.uppercased() }),
              directory.isDirectory else { throw DiscEditError.fileExists(name) }
        var inner = location
        inner.directory = directory.startSector
        for child in children {
            try child.add(to: &volume, at: inner)
        }
    }
}
