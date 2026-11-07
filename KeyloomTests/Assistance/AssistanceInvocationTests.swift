import XCTest
@testable import Keyloom

/// Proves the model boundary is only ever crossed by an explicit, permitted request: typing, matching,
/// search, toggling and a failed validation never create a session.
final class AssistanceInvocationTests: StoreTestCase {
    private func openLibrary() async throws -> SnippetLibrary {
        let url = try makeDirectory().appendingPathComponent("keyloom.sqlite")
        return try await SnippetLibrary(url: url, backupDirectory: url.deletingLastPathComponent().appendingPathComponent("backups"),
                                        now: { [clock] in clock.now }, makeID: { [ids] in ids.next() })
    }

    private func drive(_ library: SnippetLibrary) async throws {
        let template = try TokenParser.parse("Dear {argument name=\"who\" default=\"team\"}, pls fix teh text.").document
        _ = try await library.create(name: "Greeting", icon: .emoji("👋"), keyword: ";hi", tags: ["mail"], template: template)
        for query in ["", "gre", "teh", "mail", "zzz"] { _ = await library.search(query: query) }
        let matcher = library.keywordMatcher
        matcher.invalidate()
        for character in "typing ;hi then more text" { _ = matcher.feed(String(character)) }
    }

    @MainActor
    private static func makePolicy(optIn: Bool) -> (WritingAssistancePolicy, String) {
        let (defaults, name) = makeIsolatedDefaults()
        let policy = WritingAssistancePolicy(defaults: defaults, managed: FakeManagedPolicy(), availability: FakeAvailability(),
                                             locale: Locale(identifier: "en_US"))
        if optIn { policy.setAssistanceEnabled(true) }
        return (policy, name)
    }

    private func removeDomain(_ name: String) { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }

    func testSearchAndTypingNeverInvokeTheModelWithAssistanceOff() async throws {
        let model = FakeModelFactory(.reply("x"))
        let (policy, name) = await Self.makePolicy(optIn: false)
        defer { removeDomain(name) }
        let service = AssistanceService(policy: { await policy.currentSnapshot() }, sessions: model)
        try await drive(openLibrary())
        let hasPending = await service.hasPendingWork
        XCTAssertFalse(hasPending)
        XCTAssertEqual(model.created, 0)
        XCTAssertEqual(model.responded, 0)
    }

    func testSearchAndTypingNeverInvokeTheModelWhenEnabledButUnused() async throws {
        let model = FakeModelFactory(.reply("x"))
        let (policy, name) = await Self.makePolicy(optIn: true)
        defer { removeDomain(name) }
        let ready = await policy.currentSnapshot().permitsOnDeviceEdits
        XCTAssertTrue(ready)
        let service = AssistanceService(policy: { await policy.currentSnapshot() }, sessions: model)
        try await drive(openLibrary())
        await service.policyDidChange()
        await service.editorStateChanged(revision: 1, selection: try ValidatedUTF16Range(start: 0, end: 0, in: ""))
        XCTAssertEqual(model.created, 0)
        XCTAssertEqual(model.responded, 0)
    }

    func testTogglingAndRefreshingNeverInvokeTheModel() async throws {
        let model = FakeModelFactory(.reply("x"))
        let (policy, name) = await Self.makePolicy(optIn: false)
        defer { removeDomain(name) }
        _ = AssistanceService(policy: { await policy.currentSnapshot() }, sessions: model)
        await MainActor.run {
            policy.setAssistanceEnabled(true)
            policy.setSystemWritingToolsEnabled(true)
            policy.refresh()
            policy.setAssistanceEnabled(false)
        }
        XCTAssertEqual(model.created, 0)
    }

    func testAnExplicitRequestIsTheOnlyThingThatCreatesASession() async throws {
        let model = FakeModelFactory(.reply("pls fix the text"))
        let (policy, name) = await Self.makePolicy(optIn: true)
        defer { removeDomain(name) }
        let service = AssistanceService(policy: { await policy.currentSnapshot() }, sessions: model)
        let doc = try TokenParser.parse("pls fix teh text").document
        let request = EditRequest(action: .proofread, document: doc, revision: 1,
                                  selection: try ValidatedUTF16Range(start: 0, end: 16, in: doc.plainText))
        _ = try await service.propose(request)
        XCTAssertEqual(model.created, 1)
    }

    func testTurningTheSwitchOffThroughTheRealPolicyDiscardsTheSuggestion() async throws {
        let model = FakeModelFactory(.reply("pls fix the text"))
        let (policy, name) = await Self.makePolicy(optIn: true)
        defer { removeDomain(name) }
        let service = AssistanceService(policy: { await policy.currentSnapshot() }, sessions: model)
        await MainActor.run { policy.attach(service) }
        let doc = try TokenParser.parse("pls fix teh text").document
        let selection = try ValidatedUTF16Range(start: 0, end: 16, in: doc.plainText)
        let edit = try await service.propose(EditRequest(action: .proofread, document: doc, revision: 1, selection: selection))
        await MainActor.run { policy.setAssistanceEnabled(false) }
        do {
            _ = try await service.apply(edit, currentRevision: 1, currentSelection: selection)
            XCTFail("a suggestion must not apply after assistance is switched off")
        } catch {
            XCTAssertNotNil(error as? AssistanceError)
        }
        let hasPending = await service.hasPendingWork
        XCTAssertFalse(hasPending)
    }
}
