import BeebCore
import BeebHost
import Foundation
import Observation

/// How Mac keys become BBC keys, shared by all windows and saved.
///
/// Custom keys apply to every disc, and a disc image can have keys of its
/// own (a game's controls, say), which win while it's in drive 0.
@MainActor
@Observable
final class KeyboardSettings {
    static let shared = KeyboardSettings()

    /// A Mac key the user has assigned to a BBC key.
    struct Mapping: Codable, Hashable, Identifiable {
        /// macOS virtual key code.
        var keyCode: UInt16
        /// The Mac key's name when it was recorded, e.g. "F13" or "§".
        var macKeyName: String
        var beebKey: UInt8

        var id: UInt16 { keyCode }
        var key: BeebKey { BeebKey(rawValue: beebKey) }
    }

    var mode: KeyboardMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// For all discs, sorted by Mac key name.
    private(set) var mappings: [Mapping] {
        didSet {
            if let data = try? JSONEncoder().encode(mappings) {
                UserDefaults.standard.set(data, forKey: Self.mappingsKey)
            }
        }
    }

    /// Each disc image's own keys, by its path, sorted as `mappings`.
    private(set) var discMappings: [String: [Mapping]] {
        didSet {
            if let data = try? JSONEncoder().encode(discMappings) {
                UserDefaults.standard.set(data, forKey: Self.discMappingsKey)
            }
        }
    }

    /// The disc whose keys (and gamepad settings) the settings are showing
    /// (nil: all discs'). Set by Machine > Controls for This Disc.
    var editingDisc: String?

    private static let modeKey = "MacBeebKeyboardMode"
    private static let mappingsKey = "MacBeebKeyMappings"
    private static let discMappingsKey = "MacBeebDiscKeyMappings"

    private init() {
        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: Self.modeKey).flatMap(KeyboardMode.init(rawValue:)) ?? .physical
        mappings = defaults.data(forKey: Self.mappingsKey)
            .flatMap { try? JSONDecoder().decode([Mapping].self, from: $0) } ?? []
        discMappings = defaults.data(forKey: Self.discMappingsKey)
            .flatMap { try? JSONDecoder().decode([String: [Mapping]].self, from: $0) } ?? [:]
    }

    /// The keys for `disc` alone, or (nil) for all discs.
    func mappings(for disc: String?) -> [Mapping] {
        disc.map { discMappings[$0] ?? [] } ?? mappings
    }

    func setMapping(keyCode: UInt16, macKeyName: String, to key: BeebKey, disc: String? = nil) {
        var list = mappings(for: disc)
        list.removeAll { $0.keyCode == keyCode }
        list.append(Mapping(keyCode: keyCode, macKeyName: macKeyName, beebKey: key.rawValue))
        list.sort { $0.macKeyName.localizedStandardCompare($1.macKeyName) == .orderedAscending }
        setMappings(list, disc: disc)
    }

    func removeMapping(keyCode: UInt16, disc: String? = nil) {
        setMappings(mappings(for: disc).filter { $0.keyCode != keyCode }, disc: disc)
    }

    func removeAllMappings(disc: String? = nil) {
        setMappings([], disc: disc)
    }

    private func setMappings(_ list: [Mapping], disc: String?) {
        if let disc {
            discMappings[disc] = list.isEmpty ? nil : list
        } else {
            mappings = list
        }
    }

    /// A translator set up with the current mode and mappings, and those of
    /// `disc` (the path of the disc image in drive 0) on top.
    func translator(disc: String? = nil) -> KeyboardTranslator {
        let keys = (mappings + (disc.flatMap { discMappings[$0] } ?? [])).map { ($0.keyCode, $0.key) }
        return KeyboardTranslator(mode: mode, customKeys: Dictionary(keys) { _, last in last })
    }

    /// A name for a key, for the settings list: by its (Mac) key code, or
    /// the character it types without modifiers.
    static func name(keyCode: UInt16, characters: String?) -> String {
        if let name = MacKeyMap.names[keyCode] {
            return name
        }
        if let characters = characters?.uppercased(),
           let scalar = characters.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar) {
            return characters
        }
        return "Key \(keyCode)"
    }
}

extension KeyboardMode: Identifiable {
    public var id: Self { self }

    var name: String {
        switch self {
        case .physical: "BBC layout (by key position)"
        case .macLayout: "\(Platform.keyboardName) layout (by character typed)"
        }
    }
}
