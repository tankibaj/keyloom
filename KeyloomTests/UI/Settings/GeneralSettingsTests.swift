import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Keyloom

@MainActor
final class AppearanceSettingsTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "keyloom-appearance-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testDefaultsToAutoWhichFollowsTheSystem() throws {
        var applied: [NSAppearance.Name?] = []
        let settings = AppearanceSettings(defaults: try defaults()) { applied.append($0?.name) }
        XCTAssertEqual(settings.preference, .system)
        settings.applyCurrent()
        XCTAssertEqual(applied, [nil])
    }

    func testChoosingLightOrDarkAppliesItAndSurvivesARelaunch() throws {
        let store = try defaults()
        var applied: [NSAppearance.Name?] = []
        let settings = AppearanceSettings(defaults: store) { applied.append($0?.name) }
        settings.preference = .dark
        settings.preference = .light
        XCTAssertEqual(applied, [.darkAqua, .aqua])
        let relaunched = AppearanceSettings(defaults: store) { applied.append($0?.name) }
        XCTAssertEqual(relaunched.preference, .light)
        relaunched.applyCurrent()
        XCTAssertEqual(applied.last, .aqua)
    }

    func testAnUnknownStoredValueFallsBackToAuto() throws {
        let store = try defaults()
        store.set("sepia", forKey: AppearanceSettings.key)
        XCTAssertEqual(AppearanceSettings(defaults: store) { _ in }.preference, .system)
    }

    func testTheThreeChoicesAreNamedLikeThePrototype() {
        XCTAssertEqual(AppearancePreference.allCases.map(\.title), ["Auto", "Light", "Dark"])
    }
}

@MainActor
final class ShortcutSettingsModelTests: LibraryUITestCase {
    private var harness: UIHostHarness!
    private var model: ShortcutSettingsModel!

    override func setUp() async throws {
        let library = try await openTestLibrary()
        harness = makeHarness(library: library, prompter: FakePrompter(), picker: FakePicker())
        harness.controller.start()
        model = ShortcutSettingsModel(host: harness.controller)
    }

    private let commandK = ShortcutConfig(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey))

    func testStartsOnTheDefaultShortcut() {
        XCTAssertEqual(model.display, "⌃⌥Space")
        XCTAssertNil(model.message)
        XCTAssertFalse(model.isRecording)
    }

    func testRecordingAValidCombinationRegistersItAndStopsRecording() {
        model.beginRecording()
        XCTAssertTrue(model.isRecording)
        XCTAssertTrue(model.handleKey(keyCode: commandK.keyCode, modifiers: [.command]))
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(harness.hotKeys.registered, commandK)
        XCTAssertEqual(harness.controller.status.shortcut, .registered(commandK))
        XCTAssertNil(model.message)
    }

    func testAConflictIsSurfacedAndThePreviousShortcutKeepsWorking() {
        harness.hotKeys.results[commandK] = .conflict
        model.beginRecording()
        model.handleKey(keyCode: commandK.keyCode, modifiers: [.command])
        XCTAssertEqual(harness.hotKeys.registered, .defaultShortcut)
        XCTAssertTrue(model.message?.contains("already used") == true)
        XCTAssertFalse(model.isRecording)
    }

    func testACombinationWithoutCommandControlOrOptionIsRefusedAndRecordingContinues() {
        model.beginRecording()
        XCTAssertTrue(model.handleKey(keyCode: UInt32(kVK_ANSI_K), modifiers: [.shift]))
        XCTAssertTrue(model.isRecording)
        XCTAssertEqual(harness.hotKeys.registered, .defaultShortcut)
        XCTAssertTrue(model.message?.contains("Command, Control or Option") == true)
    }

    func testEscapeCancelsRecordingAndChangesNothing() {
        model.beginRecording()
        XCTAssertTrue(model.handleKey(keyCode: UInt32(kVK_Escape), modifiers: []))
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(harness.hotKeys.registered, .defaultShortcut)
    }

    func testKeysAreIgnoredWhileNotRecording() {
        XCTAssertFalse(model.handleKey(keyCode: commandK.keyCode, modifiers: [.command]))
        XCTAssertEqual(harness.hotKeys.registered, .defaultShortcut)
    }

    func testResetReturnsToControlOptionSpace() {
        model.beginRecording()
        model.handleKey(keyCode: commandK.keyCode, modifiers: [.command])
        model.reset()
        XCTAssertEqual(harness.hotKeys.registered, .defaultShortcut)
        XCTAssertEqual(model.display, "⌃⌥Space")
    }

    func testCarbonModifiersMapEveryFlag() {
        let all = ShortcutSettingsModel.carbonModifiers([.command, .option, .control, .shift, .capsLock])
        XCTAssertEqual(all, UInt32(cmdKey | optionKey | controlKey | shiftKey))
    }
}
