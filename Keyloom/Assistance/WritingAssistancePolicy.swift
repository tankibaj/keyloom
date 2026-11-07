import Foundation
import Observation

/// The per-Mac writing-assistance policy: two local opt-ins (both default off), the managed override and the
/// OS model state. Observable for the Settings panel and the editor; `observeChanges` is for non-UI parts
/// such as `AssistanceService`.
///
/// - Opt-ins live in the local `UserDefaults` domain under `localOnlyKeys`. Sync and export must exclude
///   those keys: per-device AI preferences are never synced.
/// - The OS is asked about the model only after the user opted in and nothing forces assistance off.
/// - A forced `AllowWritingAssistance=false` overrides both opt-ins; the stored preference is kept.
@MainActor
@Observable
final class WritingAssistancePolicy {
    nonisolated static let assistanceKey = "keyloom.writingAssistance.onDevice.enabled"
    nonisolated static let writingToolsKey = "keyloom.writingAssistance.systemWritingTools.enabled"
    /// Every key this type persists; sync and import/export must skip them.
    nonisolated static let localOnlyKeys: Set<String> = [assistanceKey, writingToolsKey]

    private(set) var snapshot: PolicySnapshot

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let managed: any ManagedPolicyReader
    @ObservationIgnored private let availability: any ModelAvailabilityProvider
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private var observers: [@MainActor (PolicySnapshot) -> Void] = []

    init(defaults: UserDefaults = .standard,
         managed: any ManagedPolicyReader = PreferencesManagedPolicyReader(),
         availability: any ModelAvailabilityProvider = SystemModelAvailabilityProvider(),
         locale: Locale = .current) {
        self.defaults = defaults
        self.managed = managed
        self.availability = availability
        self.locale = locale
        snapshot = PolicySnapshot(assistanceOptIn: false, writingToolsOptIn: false, managed: .notManaged, modelAvailability: nil)
        snapshot = makeSnapshot()
    }

    var isAssistanceEnabled: Bool { snapshot.assistanceOptIn }
    var isSystemWritingToolsEnabled: Bool { snapshot.writingToolsOptIn }

    func setAssistanceEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.assistanceKey)
        refresh()
    }

    func setSystemWritingToolsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.writingToolsKey)
        refresh()
    }

    /// Re-reads the managed preference and the OS model state; notifies observers when the result changed.
    /// Call when the app becomes active, since a profile can change while it runs.
    func refresh() {
        let updated = makeSnapshot()
        guard updated != snapshot else { return }
        snapshot = updated
        for observer in observers { observer(updated) }
    }

    func currentSnapshot() -> PolicySnapshot {
        refresh()
        return snapshot
    }

    /// Handlers run on the main actor after every effective change, in registration order.
    func observeChanges(_ handler: @escaping @MainActor (PolicySnapshot) -> Void) {
        observers.append(handler)
    }

    private func makeSnapshot() -> PolicySnapshot {
        let managedPolicy = managed.read()
        let assistanceOptIn = defaults.bool(forKey: Self.assistanceKey)
        let writingToolsOptIn = defaults.bool(forKey: Self.writingToolsKey)
        let model = assistanceOptIn && managedPolicy != .forbidden ? availability.availability(for: locale) : nil
        return PolicySnapshot(assistanceOptIn: assistanceOptIn, writingToolsOptIn: writingToolsOptIn,
                              managed: managedPolicy, modelAvailability: model)
    }
}

/// Reads `AllowWritingAssistance` from the app's preference domain. Only a value forced by a managed profile
/// counts, so a user-writable default is not mistaken for an organization's decision. A forced value that is
/// not a boolean fails closed.
struct PreferencesManagedPolicyReader: ManagedPolicyReader {
    static let key = "AllowWritingAssistance"

    private let isForced: @Sendable (String) -> Bool
    private let value: @Sendable (String) -> Bool?

    init(isForced: @escaping @Sendable (String) -> Bool = { key in
             CFPreferencesAppValueIsForced(key as CFString, kCFPreferencesCurrentApplication)
         },
         value: @escaping @Sendable (String) -> Bool? = { key in
             // CFPreferences returns booleans as NSNumber, which bridges to Bool only for 0 and 1.
             CFPreferencesCopyAppValue(key as CFString, kCFPreferencesCurrentApplication) as? Bool
         }) {
        self.isForced = isForced
        self.value = value
    }

    func read() -> ManagedAssistancePolicy {
        guard isForced(Self.key) else { return .notManaged }
        guard let allowed = value(Self.key) else { return .forbidden }
        return allowed ? .allowed : .forbidden
    }
}
