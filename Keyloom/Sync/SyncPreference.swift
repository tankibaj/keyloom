import Foundation

/// The per-Mac iCloud Sync switch. Off by default and saved in this Mac's own defaults, never in iCloud, so
/// turning it on here cannot turn it on anywhere else.
struct SyncPreference: Sendable {
    static let key = "KeyloomICloudSyncEnabled"

    // UserDefaults is documented thread-safe; it is not annotated Sendable by the SDK.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
