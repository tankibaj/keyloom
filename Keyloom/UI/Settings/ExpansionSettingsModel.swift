import AppKit
import Observation

/// Settings > Expansion: pause, excluded apps and the permission rows, all read from and written to the host.
/// Only counts, names and states are shown; no typed text exists here.
@MainActor @Observable
final class ExpansionSettingsModel {
    struct PermissionRow: Identifiable, Equatable {
        let title: String
        let detail: String
        let isGranted: Bool
        /// Expansion cannot work without it.
        let isRequired: Bool
        var id: String { title }
    }

    struct ExcludedApp: Identifiable, Equatable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// One line on whether typing expansion works, derived from the host. Accessibility outranks everything: without
    /// it nothing can expand, whatever else is set.
    struct Health: Equatable {
        enum Level: Equatable { case good, paused, attention }
        let level: Level
        let title: String
        let detail: String
        let symbol: String
    }

    var errorMessage: String?
    /// Kept here because the host's list is not observable.
    private(set) var excludedIDs: Set<String>
    @ObservationIgnored private let host: InputHostController
    @ObservationIgnored private let appName: @MainActor (String) -> String?

    init(host: InputHostController, appName: @escaping @MainActor (String) -> String? = ExpansionSettingsModel.systemAppName) {
        self.host = host
        self.appName = appName
        excludedIDs = host.excludedBundleIDs
    }

    var isPaused: Bool {
        get { host.status.isPaused }
        set { host.setPaused(newValue) }
    }

    var expandsInUninspectableApps: Bool {
        get { host.status.expandsInUninspectableApps }
        set { host.setExpandsInUninspectableApps(newValue) }
    }

    var permissionRows: [PermissionRow] {
        let granted = host.status.permissions
        return [
            PermissionRow(title: "Accessibility",
                          detail: "Lets Keyloom see the keyword you type and insert text. Keys are matched in memory and never stored.",
                          isGranted: granted.accessibility, isRequired: true),
        ]
    }

    var health: Health {
        if needsPermission {
            return Health(level: .attention, title: "Expansion needs Accessibility",
                          detail: "Allow Keyloom in Privacy & Security so it can see the keyword you type.",
                          symbol: "exclamationmark.triangle.fill")
        }
        if host.status.isPaused {
            return Health(level: .paused, title: "Expansion is paused",
                          detail: "Typing a keyword does nothing. Resume from the menu bar. The picker still works.",
                          symbol: "pause.circle.fill")
        }
        if host.status.isSecureInputActive {
            return Health(level: .attention, title: "Secure input is on",
                          detail: "Keyloom skips keywords until the password field or app that turned it on lets go.",
                          symbol: "lock.fill")
        }
        return Health(level: .good, title: "Expansion is on", detail: "Keywords expand as you type them in any app.",
                      symbol: "checkmark.circle.fill")
    }

    var needsPermission: Bool { permissionRows.contains { $0.isRequired && !$0.isGranted } }

    var secureInputNote: String? {
        host.status.isSecureInputActive
            ? "Secure input is on, usually in a password field or another app. Keyloom does not expand keywords while it is on."
            : nil
    }

    var excludedApps: [ExcludedApp] {
        excludedIDs.map { ExcludedApp(bundleID: $0, name: appName($0) ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Re-reads the permissions, for when the user returns from System Settings.
    func refresh() { host.refreshPermissions() }

    /// Prompts for the missing permissions. Only ever from a button.
    func requestPermissions() { host.requestPermissions() }

    func exclude(bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        excludedIDs.insert(id)
        host.setExcludedBundleIDs(excludedIDs)
    }

    /// False, with `errorMessage`, when the bundle has no bundle identifier.
    @discardableResult
    func exclude(applicationAt url: URL) -> Bool {
        guard let id = Bundle(url: url)?.bundleIdentifier else {
            errorMessage = "Keyloom can’t tell which app that is. Choose an application."
            return false
        }
        exclude(bundleID: id)
        return true
    }

    func include(bundleID: String) {
        excludedIDs.remove(bundleID)
        host.setExcludedBundleIDs(excludedIDs)
    }

    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    static func systemAppName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }
}
