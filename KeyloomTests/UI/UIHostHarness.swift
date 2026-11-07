import Foundation
import XCTest
@testable import Keyloom

/// The real `InputHostController` over the host fakes (process boundaries only), for UI tests that exercise
/// the picker, prompt and menu against the real insertion path.
@MainActor
struct UIHostHarness {
    let controller: InputHostController
    let destination: FakeDestination
    let pasteboard: FakePasteboard
    let permissions: FakePermissions
    let environment: FakeInputEnvironment
    let hotKeys: FakeHotKeys

    static let userClipboard = "user clipboard"
}

extension LibraryUITestCase {
    /// `prefix` / `suffix` surround the caret of the fake destination field.
    func makeHarness(library: SnippetLibrary, prompter: ArgumentPrompting, picker: PickerPresenting,
                     prefix: String = "Dear ", typed: String = "", suffix: String = " tail") -> UIHostHarness {
        let destination = FakeDestination(prefix: prefix, typed: typed, suffix: suffix)
        let pasteboard = FakePasteboard(userClipboard: UIHostHarness.userClipboard)
        let permissions = FakePermissions()
        let environment = FakeInputEnvironment()
        let hotKeys = FakeHotKeys()
        let tap = FakeTap()
        let suite = "keyloom-ui-tests-\(UUID().uuidString)"
        let preferences = UserDefaultsPreferences(defaults: UserDefaults(suiteName: suite)!)
        addTeardownBlock { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        let dependencies = HostDependencies(
            destination: destination, pasteboard: pasteboard, keys: FakePasteKeys(), permissions: permissions,
            environment: environment, workspace: FakeWorkspace(), hotKeys: hotKeys, makeTap: { _ in tap },
            settle: { _ in }, ownBundleID: "app.keyloom.Keyloom", permissionPollInterval: nil)
        let controller = InputHostController(library: library, prompter: prompter, picker: picker, preferences: preferences,
                                             dependencies: dependencies)
        return UIHostHarness(controller: controller, destination: destination, pasteboard: pasteboard,
                             permissions: permissions, environment: environment, hotKeys: hotKeys)
    }

    func openTestLibrary() async throws -> SnippetLibrary {
        let library = try await openLibrary()
        addTeardownBlock { [library] in await library.close() }
        return library
    }
}
