import Foundation
import BeebNetwork
import Observation

/// The networks opened most recently, newest first, for File > Open Recent
/// Network and the Network Studio's start page.
@MainActor @Observable
final class RecentNetworks {
    static let shared = RecentNetworks()
    static let limit = 10
    private static let defaultsKey = "MacBeebRecentNetworks"

    private(set) var urls: [URL]

    private init() {
        let saved = (UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []).map { URL(fileURLWithPath: $0) }
        // Self-tests' networks (in the temporary folder) once got in.
        urls = saved.filter { !Self.isTemporary($0) }
        if urls.count != saved.count {
            // They pushed the user's own off the list: fill it again from
            // the networks folder, most recently changed first.
            let found = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey]))?
                .filter { $0.pathExtension == NetworkPackage.fileExtension }
                .sorted { Self.modified($0) > Self.modified($1) } ?? []
            for url in found.map(\.standardizedFileURL) where !urls.contains(url) && urls.count < Self.limit {
                urls.append(url)
            }
            save()
        }
    }

    private static func modified(_ url: URL) -> Date {
        // A package's manifest changes as the network's saved.
        let manifest = url.appendingPathComponent("manifest.json")
        return (try? manifest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Whether a network is in the temporary folder, as self-tests' are.
    private static func isTemporary(_ url: URL) -> Bool {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(temporary)
    }

    /// The ones still there.
    var existing: [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        // Not a self-test's.
        guard !Self.isTemporary(url), !LaunchScreen.isSelfTest else { return }
        let url = url.standardizedFileURL
        urls.removeAll { $0 == url }
        urls.insert(url, at: 0)
        urls = Array(urls.prefix(Self.limit))
        save()
    }

    /// A network moved (renamed): it keeps its place in the list.
    func replace(_ old: URL, with new: URL) {
        let old = old.standardizedFileURL, new = new.standardizedFileURL
        guard urls.contains(old) else { return add(new) }
        var seen: Set<URL> = []
        urls = urls.map { $0 == old ? new : $0 }.filter { seen.insert($0).inserted }
        save()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url.standardizedFileURL }
        save()
    }

    private func save() {
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.defaultsKey)
    }

    /// Where new networks go: ~/Documents/MacBeeb Networks.
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacBeeb Networks", isDirectory: true)
    }

    /// Where new networks wait until they're kept (or deleted).
    static var draftsFolder: URL {
        URL.applicationSupportDirectory.appendingPathComponent("MacBeeb/Draft Networks", isDirectory: true)
    }

    /// A new package's place, named after `name` and not taken: in the
    /// drafts folder (a new network), or `folder`.
    static func newURL(named name: String, in folder: URL = draftsFolder) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var candidate = folder.appendingPathComponent(clean).appendingPathExtension(NetworkPackage.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(clean) \(n)").appendingPathExtension(NetworkPackage.fileExtension)
            n += 1
        }
        return candidate
    }
}
