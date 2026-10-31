import BeebCore
import BeebHost
import Foundation
import Observation

/// What game controllers do, shared by all windows and saved: for all
/// discs, and for each disc image (by path, as `KeyboardSettings`), whose
/// settings win while it's in drive 0.
@MainActor
@Observable
final class GamepadSettings {
    static let shared = GamepadSettings()

    struct Config: Codable, Equatable {
        /// nil: as for all discs.
        var mode: GamepadMode?
        /// BBC keys by `GamepadButton` raw value.
        var keys: [String: UInt8] = [:]

        var isEmpty: Bool { mode == nil && keys.isEmpty }

        func key(for button: GamepadButton) -> BeebKey? {
            keys[button.rawValue].map(BeebKey.init(rawValue:))
        }
    }

    /// For all discs.
    private(set) var config: Config {
        didSet { save(config, Self.configKey) }
    }

    /// Each disc image's own, by its path.
    private(set) var discConfigs: [String: Config] {
        didSet { save(discConfigs, Self.discConfigsKey) }
    }

    /// The buttons held on the first controller, so the settings can show
    /// which is which.
    var held: Set<GamepadButton> = []

    private static let configKey = "MacBeebGamepad"
    private static let discConfigsKey = "MacBeebDiscGamepads"

    private init() {
        let defaults = UserDefaults.standard
        config = defaults.data(forKey: Self.configKey).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
            ?? Config(mode: .joystick)
        discConfigs = defaults.data(forKey: Self.discConfigsKey)
            .flatMap { try? JSONDecoder().decode([String: Config].self, from: $0) } ?? [:]
    }

    private func save(_ value: some Encodable, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// The settings for `disc` alone, or (nil) for all discs.
    func config(for disc: String?) -> Config {
        disc.map { discConfigs[$0] ?? Config() } ?? config
    }

    func setMode(_ mode: GamepadMode?, disc: String? = nil) {
        var config = config(for: disc)
        config.mode = disc == nil ? mode ?? .joystick : mode
        setConfig(config, disc: disc)
    }

    /// Puts `key` on `button` (nil: none, or for a disc, as for all discs).
    func setKey(_ key: BeebKey?, for button: GamepadButton, disc: String? = nil) {
        var config = config(for: disc)
        config.keys[button.rawValue] = key?.rawValue
        setConfig(config, disc: disc)
    }

    func reset(disc: String? = nil) {
        setConfig(disc == nil ? Config(mode: .joystick) : Config(), disc: disc)
    }

    private func setConfig(_ new: Config, disc: String?) {
        if let disc {
            discConfigs[disc] = new.isEmpty ? nil : new
        } else {
            config = new
        }
    }

    /// The mode and keys for a controller with `disc` (the path of the disc
    /// image in drive 0) in.
    func mapping(disc: String?) -> (mode: GamepadMode, keys: [GamepadButton: BeebKey]) {
        let own = disc.flatMap { discConfigs[$0] }
        var keys: [GamepadButton: BeebKey] = [:]
        for button in GamepadButton.allCases {
            keys[button] = own?.key(for: button) ?? config.key(for: button)
        }
        return (own?.mode ?? config.mode ?? .joystick, keys)
    }
}

extension GamepadMode: Identifiable {
    public var id: Self { self }

    var name: String {
        switch self {
        case .joystick: "Joystick"
        case .keys: "Keys"
        }
    }
}

extension GamepadButton: Identifiable {
    public var id: Self { self }

    var name: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .leftShoulder: "Left Shoulder"
        case .rightShoulder: "Right Shoulder"
        case .leftTrigger: "Left Trigger"
        case .rightTrigger: "Right Trigger"
        case .leftStickButton: "Left Stick Button"
        case .rightStickButton: "Right Stick Button"
        case .menu: "Menu"
        case .options: "Options"
        }
    }
}
