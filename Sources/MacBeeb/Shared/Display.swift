import Foundation

/// How the picture is drawn.
enum DisplayStyle: String, CaseIterable, Identifiable {
    /// Nearest-neighbour pixels.
    case sharp
    /// Bilinear filtering.
    case smooth
    /// A CRT: visible scanlines whose width follows brightness, and an
    /// aperture grille when the window is big enough to show it.
    case crt

    var id: Self { self }

    var name: String {
        switch self {
        case .sharp: "Sharp Pixels"
        case .smooth: "Smooth"
        case .crt: "CRT"
        }
    }

    static let defaultsKey = "MacBeebDisplayStyle"

    static var saved: DisplayStyle {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(DisplayStyle.init(rawValue:)) ?? .sharp
    }
}

/// The monitor the BBC is plugged into, separately from how its picture is
/// drawn: a colour one, or a monochrome one with a green or amber phosphor.
enum Monitor: String, CaseIterable, Identifiable {
    case colour
    /// P1 phosphor.
    case green
    /// P3 phosphor.
    case amber

    var id: Self { self }

    var name: String {
        switch self {
        case .colour: "Colour"
        case .green: "Green Screen"
        case .amber: "Amber Screen"
        }
    }

    static let defaultsKey = "MacBeebMonitor"

    static var saved: Monitor {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Monitor.init(rawValue:)) ?? .colour
    }
}
