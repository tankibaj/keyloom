import AppKit
import XCTest
@testable import Keyloom

/// The explicit rich route writes the clipboard temporarily; these pin when it may restore and when it must not.
final class ClipboardOwnershipTests: InsertionTestCase {
    private let snippet = "Hello Bob"

    /// The destination applies a synthetic paste: the current selection is replaced with the clipboard text.
    private func pasteLands() {
        keys.onPost = { [unowned self] in destination.splice(destination.selection!, pasteboard.plain!) }
    }

    private func pasteRich(cursor: Int? = nil) async throws -> InsertionOutcome {
        let target = try await bound()
        return await engine.insert(rendered(snippet, cursor: cursor, boldRange: 6..<9), into: target, route: .richPaste, reactivating: false)
    }

    func testPasteRestoresTheUsersClipboardWhileTheChangeCountIsStillOurs() async throws {
        make()
        pasteLands()
        let outcome = try await pasteRich(cursor: 5)
        XCTAssertEqual(outcome, .replaced(mode: .richPaste, verified: true, clipboard: .restored))
        XCTAssertEqual(destination.text, "Dear Hello Bob tail")
        XCTAssertEqual(destination.selection, NSRange(location: 10, length: 0))
        XCTAssertEqual(pasteboard.plain, "user clipboard")
        XCTAssertEqual(keys.postCount, 1)
    }

    func testClipboardWrittenMeanwhileByAnotherAppIsNeverOverwritten() async throws {
        make()
        pasteLands()
        onSettle = { [unowned self] in pasteboard.otherAppCopies("newer clipboard") }
        let outcome = try await pasteRich()
        XCTAssertEqual(outcome, .replaced(mode: .richPaste, verified: true, clipboard: .restoreSkippedOwnershipLost))
        XCTAssertEqual(pasteboard.plain, "newer clipboard")
    }

    func testPasteThatNeverLandsLeavesOurSnippetOnTheClipboardSoALatePasteCannotInsertTheOldOne() async throws {
        make()
        var clipboardOutcomes: [ClipboardOutcome] = []
        engine.onClipboardOutcome = { clipboardOutcomes.append($0) }
        let target = try await bound()
        settles = 0
        let outcome = await engine.insert(rendered(snippet, boldRange: 6..<9), into: target, route: .richPaste, reactivating: false)
        XCTAssertEqual(outcome, .aborted(.writeUnconfirmed))
        XCTAssertTrue(outcome.allowsCopyOffer)
        XCTAssertEqual(clipboardOutcomes, [.restoreSkippedPasteUnconfirmed])
        XCTAssertEqual(pasteboard.plain, snippet)
        XCTAssertEqual(settles, TargetBinder.maxSettleAttempts)
    }

    func testClipboardCopiedWhileWaitingForTheAppToComeBackIsRestoredNotOverwritten() async throws {
        make()
        pasteLands()
        let target = try await bound()
        destination.onActivate = { [unowned self] _ in pasteboard.otherAppCopies("newer clipboard") }
        let outcome = await engine.insert(rendered(snippet), into: target, route: .richPaste, reactivating: true)
        XCTAssertEqual(outcome, .replaced(mode: .richPaste, verified: true, clipboard: .restored))
        XCTAssertEqual(pasteboard.plain, "newer clipboard", "the snapshot is taken after the await, so the newer copy is what comes back")
    }

    func testClipboardChangedBetweenSnapshotAndWriteRefusesAndWritesNothing() async throws {
        make()
        pasteLands()
        pasteboard.onSnapshot = { [unowned self] in pasteboard.otherAppCopies("newer clipboard") }
        let outcome = try await pasteRich()
        XCTAssertEqual(outcome, .failedClosed(.richUnsupported))
        XCTAssertTrue(outcome.allowsCopyOffer)
        XCTAssertEqual(pasteboard.plain, "newer clipboard")
        XCTAssertEqual(pasteboard.writeCount, 0)
        XCTAssertEqual(keys.postCount, 0)
        XCTAssertEqual(destination.text, "Dear ;kl tail")
        XCTAssertEqual(destination.selection, NSRange(location: 8, length: 0))
    }

    func testDestinationChangedAfterTheClipboardWriteSendsNoKeystrokeAndRestores() async throws {
        make()
        let target = try await bound()
        // The user moves the caret after the keyword was selected, between the clipboard write and the keystroke.
        pasteboard.onWrite = { [unowned self] in destination.selection = NSRange(location: 0, length: 0) }
        keys.onPost = { XCTFail("no keystroke may be sent") }
        let outcome = await engine.insert(rendered(snippet), into: target, route: .richPaste, reactivating: false)
        XCTAssertEqual(outcome, .aborted(.destinationChanged))
        XCTAssertEqual(keys.postCount, 0)
        XCTAssertEqual(pasteboard.plain, "user clipboard")
        XCTAssertEqual(destination.text, "Dear ;kl tail")
    }

    func testMissingPostEventsPermissionFailsClosedBeforeAnySelectionOrClipboardWrite() async throws {
        make()
        let target = try await bound()
        permissions.status.postEvents = false
        let outcome = await engine.insert(rendered(snippet), into: target, route: .richPaste, reactivating: false)
        XCTAssertEqual(outcome, .failedClosed(.richUnsupported))
        assertUntouched("Dear ;kl tail")
    }

    func testClipboardThatCannotBePreservedFailsClosedAndIsNeverTouched() async throws {
        make()
        pasteboard.isPreservable = false
        let target = try await bound()
        let outcome = await engine.insert(rendered(snippet), into: target, route: .richPaste, reactivating: false)
        XCTAssertEqual(outcome, .failedClosed(.richUnsupported))
        assertUntouched("Dear ;kl tail")
    }

    func testRefusedPostRestoresClipboardAndPutsTheCaretBack() async throws {
        make()
        keys.succeeds = false
        let outcome = try await pasteRich()
        XCTAssertEqual(outcome, .aborted(.writeFailed))
        XCTAssertEqual(pasteboard.plain, "user clipboard")
        XCTAssertEqual(destination.text, "Dear ;kl tail")
        XCTAssertEqual(destination.selection, NSRange(location: 8, length: 0))
    }

    func testCancelledBeforeSelectingNeverTouchesSelectionOrClipboard() async throws {
        make()
        let target = try await bound()
        destination.onActivate = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let outcome = await Task { [engine = engine!, target] in
            await engine.insert(self.rendered(self.snippet), into: target, route: .richPaste, reactivating: true)
        }.value
        XCTAssertEqual(outcome, .aborted(.cancelled))
        XCTAssertEqual(pasteboard.writeCount, 0)
        XCTAssertEqual(destination.text, "Dear ;kl tail")
    }

    func testExplicitCopyWritesPlainAndStyledAndNeverRestores() throws {
        make()
        let outcome = engine.copy(rendered(snippet, boldRange: 6..<9))
        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(pasteboard.plain, snippet)
        let rtf = try XCTUnwrap(pasteboard.items.first?["public.rtf"])
        let styled = try XCTUnwrap(NSAttributedString(rtf: rtf, documentAttributes: nil))
        XCTAssertEqual(styled.string, snippet)
        let boldTraits = (styled.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits
        let plainTraits = (styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits
        XCTAssertEqual(boldTraits?.contains(.bold), true)
        XCTAssertEqual(plainTraits?.contains(.bold), false)
    }
}
