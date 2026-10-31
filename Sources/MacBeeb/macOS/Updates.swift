import Sparkle

/// Sparkle software updates. Only release builds carry the feed URL and
/// public key (scripts/release.sh adds the key); other builds don't check.
@MainActor
final class Updates {
    static let shared = Updates()

    private let controller: SPUStandardUpdaterController?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let configured = info["SUFeedURL"] != nil && info["SUPublicEDKey"] != nil
        controller = configured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
