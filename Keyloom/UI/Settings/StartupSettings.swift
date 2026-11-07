import Foundation
import Observation
import ServiceManagement

/// The login item, as `SMAppService.mainApp` exposes it. A protocol so tests and UI-test runs never touch the real
/// login items.
@MainActor
protocol LoginItem: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: @MainActor LoginItem {}

/// Stands in for the login item under XCTest and UI tests: registering only flips its own status.
@MainActor
final class InertLoginItem: LoginItem {
    private(set) var status: SMAppService.Status = .notRegistered

    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
}

/// Settings > General > Startup: open at login (the system's own state, never a copy) and whether the menu bar item
/// is shown. Hiding the item is safe: Keyloom is a regular Dock app, so the library, Settings and Quit stay reachable.
@MainActor @Observable
final class StartupSettings {
    static let showInMenuBarKey = "app.keyloom.showInMenuBar"

    private(set) var loginStatus: SMAppService.Status
    private(set) var errorMessage: String?

    var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar, forKey: Self.showInMenuBarKey) }
    }

    @ObservationIgnored private let loginItem: any LoginItem
    @ObservationIgnored private let defaults: UserDefaults

    init(loginItem: any LoginItem, defaults: UserDefaults) {
        self.loginItem = loginItem
        self.defaults = defaults
        loginStatus = loginItem.status
        showInMenuBar = defaults.object(forKey: Self.showInMenuBarKey) as? Bool ?? true
    }

    /// On while registered, including when macOS still waits for the user to allow it.
    var opensAtLogin: Bool {
        get { loginStatus == .enabled || loginStatus == .requiresApproval }
        set {
            do {
                if newValue { try loginItem.register() } else { try loginItem.unregister() }
                errorMessage = nil
            } catch {
                errorMessage = "Couldn’t change the login item: \(error.localizedDescription)"
            }
            refresh()
        }
    }

    var needsApproval: Bool { loginStatus == .requiresApproval }

    /// Re-reads the status, for when the user changes Login Items in System Settings.
    func refresh() { loginStatus = loginItem.status }
}
