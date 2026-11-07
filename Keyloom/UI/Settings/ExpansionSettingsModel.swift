import AppKit
import Observation

/// Settings > Expansion: pause, excluded apps and the permission rows, all read from and written to the host.
/// Only counts, names and states are shown; no typed text exists here.
@MainActor @Observable
final class ExpansionSettingsModel {
    enum PermissionKind: Hashable { case accessibility, inputMonitoring, pasteEvents }

    struct PermissionRow: Identifiable, Equatable {
        let kind: PermissionKind
        let title: String
        let detail: String
        let isGranted: Bool
        /// Expansion cannot work without it.
        let isRequired: Bool
        var id: PermissionKind { kind }
    }

    struct ExcludedApp: Identifiable, Equatable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
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

    var permissionRows: [PermissionRow] {
        let granted = host.status.permissions
        return [
            PermissionRow(kind: .accessibility, title: "Accessibility",
                          detail: "Lets Keyloom read the field you are typing in and replace the keyword with the snippet.",
                          isGranted: granted.accessibility, isRequired: true),
            PermissionRow(kind: .inputMonitoring, title: "Input Monitoring",
                          detail: "Lets Keyloom notice a keyword as you type it. Keys are matched in memory and never stored.",
                          isGranted: granted.inputMonitoring, isRequired: true),
            PermissionRow(kind: .pasteEvents, title: "Post Events (optional)",
                          detail: "Only needed to insert styled text with the explicit rich-paste route.",
                          isGranted: granted.postEvents, isRequired: false),
        ]
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

    static func systemSettingsURL(for kind: PermissionKind) -> URL {
        let pane = switch kind {
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .pasteEvents: "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    static func systemAppName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }
}
