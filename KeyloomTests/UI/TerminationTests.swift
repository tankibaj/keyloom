import AppKit
import XCTest
@testable import Keyloom

/// Quit with a dirty editor and the `.terminateLater` reply: AppKit is always answered, exactly once, even when the
/// sync shutdown never returns.
@MainActor
final class TerminationTests: LibraryUITestCase {
    @MainActor final class Log {
        var shutdowns = 0
        var replies: [Bool] = []
        var onReply: (() -> Void)?
    }

    @MainActor private struct Rig {
        let delegate: AppDelegate
        let model: AppModel
        let log = Log()
        let shutdownGate = AsyncGate()
        let timerGate = AsyncGate()
    }

    /// A model with a dirty editor and its Quit sheet raised, wired to a delegate whose shutdown and timer are gated.
    private func rig(shutdownFinishes: Bool) async throws -> Rig {
        let model = AppModel(dataDirectory: try makeDirectory(), openLibrary: { [self] directory in try await openLibrary(at: directory) })
        await model.open()
        let library = try XCTUnwrap(model.library)
        let snippet = try await seed(library, "Probe")
        await model.libraryModel?.refresh()
        await model.requestSelection(snippet.id)
        model.editor?.draft.name = "Edited"

        let rig = Rig(delegate: AppDelegate(), model: model)
        let (delegate, log, shutdownGate, timerGate) = (rig.delegate, rig.log, rig.shutdownGate, rig.timerGate)
        delegate.model = model
        delegate.shutdown = { log.shutdowns += 1; if !shutdownFinishes { await shutdownGate.wait() } }
        delegate.sleep = { _ in await timerGate.wait() }
        delegate.replyToTermination = { log.replies.append($0); log.onReply?() }
        model.quitAction = { _ = delegate.applicationShouldTerminate(NSApp) }
        addTeardownBlock { await shutdownGate.open(); await timerGate.open() }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel, "dirty edit: the sheet is raised, the app stays")
        XCTAssertEqual(model.pendingDismissal, .quit)
        return rig
    }

    private func waitForReply(_ rig: Rig) async {
        guard rig.log.replies.isEmpty else { return }
        let replied = expectation(description: "termination reply")
        rig.log.onReply = { replied.fulfill() }
        await fulfillment(of: [replied], timeout: 5)
    }

    func testDiscardChangesQuitsAndRepliesToAppKit() async throws {
        let rig = try await rig(shutdownFinishes: true)
        await rig.model.resolvePending(.discard)
        await waitForReply(rig)
        XCTAssertEqual(rig.log.replies, [true])
        XCTAssertEqual(rig.log.shutdowns, 1)
    }

    func testSaveQuitsAndRepliesToAppKit() async throws {
        let rig = try await rig(shutdownFinishes: true)
        await rig.model.resolvePending(.save)
        await waitForReply(rig)
        XCTAssertEqual(rig.log.replies, [true])
        XCTAssertEqual(rig.log.shutdowns, 1)
    }

    func testKeepEditingStaysRunning() async throws {
        let rig = try await rig(shutdownFinishes: true)
        await rig.model.resolvePending(.keepEditing)
        XCTAssertEqual(rig.log.shutdowns, 0, "no shutdown, no reply")
        XCTAssertEqual(rig.log.replies, [])
        XCTAssertNil(rig.model.pendingDismissal)
    }

    func testReplyIsSentWhenShutdownNeverReturns() async throws {
        let rig = try await rig(shutdownFinishes: false)
        await rig.model.resolvePending(.discard)
        await rig.timerGate.open()
        await waitForReply(rig)
        XCTAssertEqual(rig.log.replies, [true], "the timeout answers AppKit although shutdown is stuck")
    }

    func testReplyIsSentOnceWhenShutdownFinishesAndTheTimerFiresLater() async throws {
        let rig = try await rig(shutdownFinishes: true)
        await rig.model.resolvePending(.discard)
        await waitForReply(rig)
        await rig.timerGate.open()
        await Task.yield()
        XCTAssertEqual(rig.log.replies, [true])
    }

    func testASecondQuitWhileTheReplyIsPendingStartsNoSecondShutdown() async throws {
        let rig = try await rig(shutdownFinishes: false)
        await rig.model.resolvePending(.discard)
        XCTAssertEqual(rig.delegate.applicationShouldTerminate(NSApp), .terminateLater)
        await rig.timerGate.open()
        await waitForReply(rig)
        XCTAssertEqual(rig.log.shutdowns, 1)
        XCTAssertEqual(rig.log.replies, [true])
    }

    func testWithoutAShutdownHookTheAppQuitsAtOnce() {
        XCTAssertEqual(AppDelegate().applicationShouldTerminate(NSApp), .terminateNow)
    }

    /// `terminate` waits for the reply in a nested run loop. Called synchronously from the sheet button's main-actor
    /// task, that task keeps the main actor and the reply task never runs (the app hung after Discard Changes).
    func testRequestTerminationLeavesTheCallingTaskBeforeTerminating() async {
        let called = expectation(description: "terminate called")
        var terminated = false
        AppDelegate.requestTermination { terminated = true; called.fulfill() }
        XCTAssertFalse(terminated, "terminate must not run inside the calling task")
        await fulfillment(of: [called], timeout: 5)
    }
}
