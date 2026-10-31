import Foundation

/// Invitation links (macbeeb://join…) waiting for the Join window.
@MainActor
final class JoinRequests {
    static let shared = JoinRequests()
    static let arrived = Notification.Name("MacBeebJoinRequest")
    private var pending: URL?
    /// File ▸ Add Remote Elite: join with an Elite player.
    private var wantsElite = false

    func requestElite() {
        wantsElite = true
        NotificationCenter.default.post(name: Self.arrived, object: nil)
    }

    func takeElite() -> Bool {
        defer { wantsElite = false }
        return wantsElite
    }

    func handle(_ url: URL) {
        pending = url
        NotificationCenter.default.post(name: Self.arrived, object: nil)
    }

    func take() -> URL? {
        defer { pending = nil }
        return pending
    }

    static func isJoinLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "macbeeb" && url.host?.lowercased() == "join"
    }
}
