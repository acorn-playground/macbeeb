import CGtk
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Help > Check for Updates: whether there's a newer release than this
/// one on GitHub, and how to get it. (The Mac's updates itself with
/// Sparkle; on Linux MacBeeb's built from its source, so this says what's
/// new and how to update.) Only when asked: nothing's checked otherwise.
@MainActor
enum Updates {
    static let latest = URL(string: "https://api.github.com/repos/acorn-playground/macbeeb/releases/latest")!

    private struct Release: Decodable {
        var tag_name: String
        var html_url: String
        var body: String?
    }

    static func check() {
        let parent = Application.shared.activeWindow.map(Widget.init)
        Task {
            var request = URLRequest(url: latest)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let release: Release
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                release = try JSONDecoder().decode(Release.self, from: data)
            } catch {
                AlertDialog("Couldn’t check for updates",
                            body: "MacBeeb couldn’t reach GitHub to see if there’s a newer release. Check your connection, and try again.")
                    .response("ok", "_OK", .suggested)
                    .defaults(default: "ok", close: "ok")
                    .present(over: parent)
                return
            }
            let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            let current = Platform.appVersion
            guard WhatsNew.isNewer(version, than: current) else {
                AlertDialog("MacBeeb is up to date", body: "\(current) is the newest release.")
                    .response("ok", "_OK", .suggested)
                    .defaults(default: "ok", close: "ok")
                    .present(over: parent)
                return
            }
            AlertDialog("MacBeeb \(version) is available",
                        body: "You have \(current). To update, in your copy of MacBeeb’s source: git pull, then scripts/install-linux.sh.")
                .response("later", "_Later")
                .response("notes", "_Release Notes", .suggested)
                .defaults(default: "notes", close: "later")
                .choose(over: parent) { response in
                    if response == "notes", let url = URL(string: release.html_url) {
                        Platform.open(url)
                    }
                }
        }
    }
}
