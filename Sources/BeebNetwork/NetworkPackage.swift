import Foundation

/// A network on disc: a `.macbeebnet` package (a folder Finder shows as one
/// file) with `manifest.json`, the project, `Media`, the copies of its
/// discs, and `ROMs`, copies of the user's ROMs its machines have in their
/// sockets (so the network works on another Mac).
public enum NetworkPackage {
    public static let fileExtension = "macbeebnet"
    static let manifestName = "manifest.json"
    static let mediaFolder = "Media"
    static let romsFolder = "ROMs"

    public enum LoadError: Error, CustomStringConvertible {
        case notANetwork
        case newerVersion(Int)

        public var description: String {
            switch self {
            case .notANetwork: "This isn't a MacBeeb network: it has no manifest."
            case .newerVersion(let version): "This network was saved by a newer MacBeeb (format \(version)). Update MacBeeb to open it."
            }
        }
    }

    public static func load(from url: URL) throws -> NetworkProject {
        let manifest = url.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw LoadError.notANetwork }
        let data = try Data(contentsOf: manifest)
        let version = try JSONDecoder().decode(Versioned.self, from: data).schemaVersion
        guard version <= NetworkProject.currentSchemaVersion else { throw LoadError.newerVersion(version) }
        // Migrations from older versions go here, by version.
        return try JSONDecoder().decode(NetworkProject.self, from: data)
    }

    /// Writes the manifest (atomically) and makes the package if it's new.
    public static func save(_ project: NetworkProject, to url: URL) throws {
        try FileManager.default.createDirectory(at: mediaURL(in: url), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: url.appendingPathComponent(manifestName), options: .atomic)
    }

    /// A new network from a template, saved at `url` with its discs.
    @discardableResult
    public static func create(_ template: NetworkTemplate, named name: String? = nil, at url: URL) throws -> NetworkProject {
        var project = template.makeProject()
        if let name, !name.isEmpty { project.name = name }
        try save(project, to: url)
        for disc in try template.discs(for: project) {
            let stored = UUID().uuidString.prefix(8) + "-" + disc.name
            try Data(disc.image).write(to: mediaURL(in: url).appendingPathComponent(String(stored)), options: .atomic)
            project[disc.node]?.discs[disc.drive] = MediaReference(storedName: String(stored), displayName: disc.name)
        }
        for disc in template.hardDiscs(for: project) {
            project[disc.node]?.hardDisc = try storeHardDisc(disc.contents, named: disc.name, in: url)
        }
        try save(project, to: url)
        return project
    }

    /// Puts a hard disc in the package, as `name`.dat with its .dsc.
    public static func storeHardDisc(_ contents: (image: [UInt8], parameters: [UInt8]), named name: String,
                                     in package: URL) throws -> MediaReference {
        let folder = mediaURL(in: package)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let media = MediaReference(storedName: UUID().uuidString.prefix(8) + "-" + name + ".dat", displayName: name)
        try Data(contents.image).write(to: url(of: media, in: package), options: .atomic)
        try Data(contents.parameters).write(to: parametersURL(of: media, in: package), options: .atomic)
        return media
    }

    /// Copies a hard disc (and its .dsc) within the package, for a copy of
    /// its machine.
    public static func copyHardDisc(_ media: MediaReference, in package: URL) throws -> MediaReference {
        let copy = MediaReference(storedName: UUID().uuidString.prefix(8) + "-" + media.displayName + ".dat",
                                  displayName: media.displayName)
        try FileManager.default.copyItem(at: url(of: media, in: package), to: url(of: copy, in: package))
        if FileManager.default.fileExists(atPath: parametersURL(of: media, in: package).path) {
            try FileManager.default.copyItem(at: parametersURL(of: media, in: package), to: parametersURL(of: copy, in: package))
        }
        return copy
    }

    /// A hard disc's .dsc, beside its .dat.
    public static func parametersURL(of media: MediaReference, in package: URL) -> URL {
        url(of: media, in: package).deletingPathExtension().appendingPathExtension("dsc")
    }

    public static func mediaURL(in package: URL) -> URL {
        package.appendingPathComponent(mediaFolder, isDirectory: true)
    }

    /// Copies a disc image into the package, under a new name, so the
    /// network's machines write to the copy.
    public static func importMedia(_ source: URL, into package: URL) throws -> MediaReference {
        let folder = mediaURL(in: package)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString.prefix(8) + "-" + source.lastPathComponent
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(String(name)))
        return MediaReference(storedName: String(name), displayName: source.lastPathComponent, originalPath: source.path)
    }

    public static func url(of media: MediaReference, in package: URL) -> URL {
        mediaURL(in: package).appendingPathComponent(media.storedName)
    }

    public static func romsURL(in package: URL) -> URL {
        package.appendingPathComponent(romsFolder, isDirectory: true)
    }

    /// Where the network's machines find their ROMs: its own copies, then
    /// the library.
    public static func romSource(for package: URL) -> ROMSource {
        ROMSource(folders: [romsURL(in: package), ROMLibrary.defaultFolder])
    }

    /// Copies the ROMs the network's machines use, from `library`, into the
    /// package where it hasn't them already; and removes the copies none
    /// of them use now. ROMs the library hasn't either are left missing.
    public static func syncROMs(of project: NetworkProject, into package: URL, library: ROMSource = .library) throws {
        let folder = romsURL(in: package)
        let used = Set(project.nodes.compactMap(\.setup).flatMap(\.pluggedROMs).map(\.id))
        if !used.isEmpty {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for id in used {
            let target = folder.appendingPathComponent(ROMSource.fileName(for: id))
            guard !FileManager.default.fileExists(atPath: target.path), let data = library.data(for: id) else { continue }
            try Data(data).write(to: target, options: .atomic)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "rom" && !used.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Media the manifest no longer mentions.
    public static func unusedMedia(of project: NetworkProject, in package: URL) -> [URL] {
        let hardDiscs = project.nodes.compactMap(\.hardDisc).flatMap { media in
            [media.storedName, parametersURL(of: media, in: package).lastPathComponent]
        }
        let used = Set(project.nodes.flatMap { $0.discs.values.map(\.storedName) } + hardDiscs)
        let files = (try? FileManager.default.contentsOfDirectory(at: mediaURL(in: package), includingPropertiesForKeys: nil)) ?? []
        return files.filter { !used.contains($0.lastPathComponent) }
    }

    private struct Versioned: Decodable {
        var schemaVersion: Int
    }
}
