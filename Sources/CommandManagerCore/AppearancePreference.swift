import Foundation

/// The app's light/dark choice. `system` follows macOS.
public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    /// UserDefaults key the choice is stored under.
    public static let defaultsKey = "appearance"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// Reads the stored choice; unknown or missing values fall back to `system`.
    public static func stored(in defaults: UserDefaults = .standard) -> AppearancePreference {
        defaults.string(forKey: defaultsKey).flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }
}
