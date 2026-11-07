import Carbon.HIToolbox
import XCTest
@testable import Keyloom

final class ShortcutDisplayTests: XCTestCase {
    func testTheDefaultShortcutReadsControlOptionSpace() {
        XCTAssertEqual(ShortcutDisplay.string(for: .defaultShortcut), "⌃⌥Space")
    }

    func testModifiersFollowTheSystemOrderAndNamedKeysUseTheirGlyphs() {
        let config = ShortcutConfig(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(ShortcutDisplay.string(for: config), "⌃⌥⇧⌘↩")
        XCTAssertEqual(ShortcutDisplay.string(for: ShortcutConfig(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey))), "⌘F5")
    }

    func testALetterKeyShowsTheLayoutCharacter() {
        let text = ShortcutDisplay.string(for: ShortcutConfig(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey)))
        XCTAssertTrue(text.hasPrefix("⌘") && text.count == 2, text)
    }

    func testOnlyAWorkingShortcutHasNoMessage() {
        let config = ShortcutConfig.defaultShortcut
        XCTAssertNil(ShortcutDisplay.message(for: .registered(config)))
        XCTAssertNil(ShortcutDisplay.message(for: .unregistered))
        XCTAssertTrue(ShortcutDisplay.message(for: .conflict(config))?.contains("already used") == true)
        XCTAssertTrue(ShortcutDisplay.message(for: .failed(config, status: -1))?.contains("refused") == true)
        XCTAssertTrue(ShortcutDisplay.message(for: .invalid(ShortcutConfig(keyCode: 0, modifiers: UInt32(shiftKey))))?.contains("Command, Control or Option") == true)
    }

    func testKeycapsListEachModifierThenTheKey() {
        XCTAssertEqual(ShortcutDisplay.keys(for: .defaultShortcut), ["⌃", "⌥", "Space"])
        XCTAssertEqual(ShortcutDisplay.keys(for: ShortcutConfig(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey))), ["⌘", "F5"])
    }
}
