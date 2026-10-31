import Foundation
import Observation

/// The disc images used most recently, newest first, for File > Open Recent
/// Disc. Kept in the user's defaults (the app isn't sandboxed, so a path is
/// enough).
@MainActor @Observable
final class RecentDiscs {
    static let shared = RecentDiscs()
    static let limit = 10
    private static let defaultsKey = "MacBeebRecentDiscs"

    private(set) var urls: [URL]

    private init() {
        urls = (UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// Puts `url` at the top.
    func add(_ url: URL) {
        let url = url.standardizedFileURL
        urls.removeAll { $0 == url }
        urls.insert(url, at: 0)
        urls = Array(urls.prefix(Self.limit))
        save()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url }
        save()
    }

    func clear() {
        urls = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.defaultsKey)
    }
}
