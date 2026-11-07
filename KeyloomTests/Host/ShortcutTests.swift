import Carbon.HIToolbox
import XCTest
@testable import Keyloom

@MainActor
final class ShortcutTests: XCTestCase {
    private let hotKeys = FakeHotKeys()
    private var presses = 0
    private var manager: ShortcutManager!

    override func setUp() async throws {
        presses = 0
        manager = ShortcutManager(registrar: hotKeys) { [unowned self] in presses += 1 }
    }

    private let other = ShortcutConfig(keyCode: 46, modifiers: UInt32(controlKey | optionKey))

    func testDefaultIsControlOptionSpace() {
        XCTAssertEqual(ShortcutConfig.defaultShortcut, ShortcutConfig(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)))
    }

    func testRegistersAndPressInvokesTheHook() {
        XCTAssertEqual(manager.apply(.defaultShortcut), .registered(.defaultShortcut))
        hotKeys.press()
        XCTAssertEqual(presses, 1)
    }

    func testConflictIsSurfacedAndNothingIsActive() {
        hotKeys.results[.defaultShortcut] = .conflict
        XCTAssertEqual(manager.apply(.defaultShortcut), .conflict(.defaultShortcut))
        XCTAssertNil(hotKeys.registered)
    }

    func testOtherRegistrationFailureCarriesTheStatus() {
        hotKeys.results[.defaultShortcut] = .failed(-50)
        XCTAssertEqual(manager.apply(.defaultShortcut), .failed(.defaultShortcut, status: -50))
    }

    func testShortcutWithoutACommandControlOrOptionModifierIsRefusedBeforeRegistering() {
        let bare = ShortcutConfig(keyCode: 0, modifiers: UInt32(shiftKey))
        XCTAssertEqual(manager.apply(bare), .invalid(bare))
        XCTAssertEqual(manager.apply(ShortcutConfig(keyCode: 0, modifiers: 0)), .invalid(ShortcutConfig(keyCode: 0, modifiers: 0)))
        XCTAssertTrue(hotKeys.registerCalls.isEmpty)
    }

    func testChangingTheShortcutReplacesTheOldRegistration() {
        _ = manager.apply(.defaultShortcut)
        XCTAssertEqual(manager.apply(other), .registered(other))
        XCTAssertEqual(hotKeys.registered, other)
    }

    func testFailedChangeKeepsThePreviousShortcutWorking() {
        _ = manager.apply(.defaultShortcut)
        hotKeys.results[other] = .conflict
        XCTAssertEqual(manager.apply(other), .conflict(other))
        XCTAssertEqual(hotKeys.registered, .defaultShortcut)
        hotKeys.press()
        XCTAssertEqual(presses, 1)
    }

    func testRemoveUnregisters() {
        _ = manager.apply(.defaultShortcut)
        manager.remove()
        XCTAssertNil(hotKeys.registered)
        XCTAssertEqual(manager.state, .unregistered)
    }

    func testConfigSurvivesEncoding() throws {
        let data = try JSONEncoder().encode(other)
        XCTAssertEqual(try JSONDecoder().decode(ShortcutConfig.self, from: data), other)
    }
}
