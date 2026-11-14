import AppKit
import Observation

/// Light, Dark or Auto (follow the system). Auto is the default: the app sets nothing until the user chooses.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil lets macOS decide.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The appearance override, stored per Mac in the app's defaults. `apply` is `NSApp.appearance` in the app.
@MainActor @Observable
final class AppearanceSettings {
    static let key = "keyloom.appearance"

    var preference: AppearancePreference {
        didSet {
            guard preference != oldValue else { return }
            defaults.set(preference.rawValue, forKey: Self.key)
            apply(preference.appearance)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let apply: @MainActor (NSAppearance?) -> Void

    init(defaults: UserDefaults, apply: @escaping @MainActor (NSAppearance?) -> Void = { NSApp.appearance = $0 }) {
        self.defaults = defaults
        self.apply = apply
        preference = defaults.string(forKey: Self.key).flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    /// Call once at launch so a saved choice takes effect before any window shows.
    func applyCurrent() { apply(preference.appearance) }
}
