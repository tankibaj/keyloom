import Foundation

/// What the user configured for the input host. No typed text, ever.
struct HostPreferences: Codable, Equatable, Sendable {
    var shortcut: ShortcutConfig = .defaultShortcut
    var excludedBundleIDs: Set<String> = []
}

protocol PreferencesStoring: AnyObject {
    func load() -> HostPreferences
    func save(_ preferences: HostPreferences)
}

final class UserDefaultsPreferences: PreferencesStoring {
    private static let key = "app.keyloom.host.preferences"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Unreadable or missing data falls back to the defaults.
    func load() -> HostPreferences {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(HostPreferences.self, from: $0) } ?? HostPreferences()
    }

    func save(_ preferences: HostPreferences) {
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Self.key)
    }
}
