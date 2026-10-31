import Foundation

/// What MacBeeb shows when it opens: the welcome screen, or straight into
/// one of its three parts. Chosen on the welcome screen and in Settings.
enum LaunchScreen: String, CaseIterable, Identifiable {
    case welcome
    case machine
    case games
    case network

    var id: String { rawValue }

    static let defaultsKey = "MacBeebLaunchScreen"

    var title: String {
        switch self {
        case .welcome: "The Welcome Screen"
        case .machine: "A BBC Micro"
        case .games: "The Game Library"
        case .network: "The Network Studio"
        }
    }

    /// The setting. It's new in 1.5, so everyone starts with the welcome
    /// screen, whatever they opened with before (the old setting, opening
    /// with only the Game Library, isn't carried over).
    static var preference: LaunchScreen {
        get {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(LaunchScreen.init(rawValue:)) ?? .welcome
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// What this launch shows: the setting as it was when the app started.
    /// Self-tests and window captures need a machine.
    nonisolated static let atLaunch: LaunchScreen = isSelfTest ? .machine : preference

    /// Whether this is a self-test or a window capture run, which mustn't
    /// change the user's things (their recent networks).
    nonisolated static let isSelfTest: Bool = {
        let defaults = UserDefaults.standard
        return ["MacBeebSelfTest", "MacBeebNetworkSelfTest", "MacBeebMCPSelfTest", "MacBeebCaptureDirectory"]
            .contains { defaults.string(forKey: $0) != nil }
    }()
}
