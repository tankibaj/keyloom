import XCTest
import os
@testable import Keyloom

@MainActor
final class WritingAssistancePolicyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        let isolated = makeIsolatedDefaults()
        defaults = isolated.defaults
        suiteName = isolated.name
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makePolicy(managed: ManagedAssistancePolicy = .notManaged, model: ModelAvailability = .available)
        -> (WritingAssistancePolicy, FakeManagedPolicy, FakeAvailability) {
        let managedFake = FakeManagedPolicy(managed)
        let availability = FakeAvailability(model)
        let policy = WritingAssistancePolicy(defaults: defaults, managed: managedFake, availability: availability,
                                             locale: Locale(identifier: "en_US"))
        return (policy, managedFake, availability)
    }

    func testBothOptInsDefaultOffAndNothingIsAskedOfTheOS() {
        let (policy, _, availability) = makePolicy()
        XCTAssertEqual(policy.snapshot.assistance, .off)
        XCTAssertEqual(policy.snapshot.writingTools, .off)
        XCTAssertFalse(policy.snapshot.permitsOnDeviceEdits)
        XCTAssertEqual(policy.snapshot.writingToolsBehavior(forProseField: true), .none)
        XCTAssertEqual(availability.queries, 0, "model availability is only checked after an explicit opt-in")
    }

    func testOptInsAreIndependent() {
        let (policy, _, _) = makePolicy()
        policy.setAssistanceEnabled(true)
        XCTAssertEqual(policy.snapshot.assistance, .ready)
        XCTAssertEqual(policy.snapshot.writingTools, .off)
        policy.setAssistanceEnabled(false)
        policy.setSystemWritingToolsEnabled(true)
        XCTAssertEqual(policy.snapshot.assistance, .off)
        XCTAssertEqual(policy.snapshot.writingTools, .allowed)
    }

    func testOptInsPersistPerMacInTheLocalDomainOnly() {
        let (first, _, _) = makePolicy()
        first.setAssistanceEnabled(true)
        first.setSystemWritingToolsEnabled(true)
        let (second, _, _) = makePolicy()
        XCTAssertTrue(second.isAssistanceEnabled)
        XCTAssertTrue(second.isSystemWritingToolsEnabled)
        let stored = Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? [])
        XCTAssertEqual(stored, WritingAssistancePolicy.localOnlyKeys, "every stored key is declared never-synced")
        XCTAssertEqual(stored.count, 2)
    }

    func testManagedOffOverridesBothOptInsAndSkipsTheOS() {
        let (policy, _, availability) = makePolicy(managed: .forbidden)
        policy.setAssistanceEnabled(true)
        policy.setSystemWritingToolsEnabled(true)
        XCTAssertEqual(policy.snapshot.assistance, .managedOff)
        XCTAssertEqual(policy.snapshot.writingTools, .managedOff)
        XCTAssertFalse(policy.snapshot.permitsOnDeviceEdits)
        XCTAssertEqual(policy.snapshot.writingToolsBehavior(forProseField: true), .none)
        XCTAssertEqual(availability.queries, 0)
        XCTAssertTrue(policy.isAssistanceEnabled, "the user's own preference is kept, only overridden")
    }

    func testManagedAllowDoesNotSwitchAnythingOn() {
        let (policy, _, _) = makePolicy(managed: .allowed)
        XCTAssertEqual(policy.snapshot.assistance, .off)
        XCTAssertEqual(policy.snapshot.writingTools, .off)
    }

    func testEachModelStateIsReportedAsExposed() {
        let cases: [(ModelAvailability, AssistanceState)] = [
            (.available, .ready),
            (.downloading, .downloading),
            (.unsupportedLanguage, .unsupportedLanguage),
            (.unavailable(.deviceNotEligible), .unavailable(.deviceNotEligible)),
            (.unavailable(.appleIntelligenceNotEnabled), .unavailable(.appleIntelligenceNotEnabled)),
            (.unavailable(.unspecified), .unavailable(.unspecified)),
        ]
        for (model, expected) in cases {
            let (policy, _, _) = makePolicy(model: model)
            policy.setAssistanceEnabled(true)
            XCTAssertEqual(policy.snapshot.assistance, expected)
            XCTAssertEqual(policy.snapshot.permitsOnDeviceEdits, expected == .ready)
        }
    }

    func testModelAvailabilityIsSeparateFromSystemWritingTools() {
        let (policy, _, _) = makePolicy(model: .unavailable(.deviceNotEligible))
        policy.setSystemWritingToolsEnabled(true)
        XCTAssertEqual(policy.snapshot.writingTools, .allowed, "the system decides Writing Tools; the model state does not gate it")
        XCTAssertEqual(policy.snapshot.writingToolsBehavior(forProseField: true), .default)
        policy.setAssistanceEnabled(true)
        XCTAssertEqual(policy.snapshot.assistance, .unavailable(.deviceNotEligible))
        XCTAssertEqual(policy.snapshot.writingTools, .allowed)
    }

    func testWritingToolsStayOffInNonProseFieldsAndWhenOptedOut() {
        let (policy, _, _) = makePolicy()
        policy.setSystemWritingToolsEnabled(true)
        XCTAssertEqual(policy.snapshot.writingToolsBehavior(forProseField: true), .default)
        XCTAssertEqual(policy.snapshot.writingToolsBehavior(forProseField: false), .none)
        policy.setSystemWritingToolsEnabled(false)
        XCTAssertEqual(policy.snapshot.writingToolsBehavior(forProseField: true), .none)
    }

    func testAssistanceOnWithWritingToolsOffAddsNoRewriteRoute() {
        let (policy, _, _) = makePolicy()
        policy.setAssistanceEnabled(true)
        XCTAssertEqual(policy.snapshot.writingToolsBehavior(forProseField: true), .none)
        policy.setSystemWritingToolsEnabled(true)
        policy.setAssistanceEnabled(false)
        XCTAssertFalse(policy.snapshot.permitsOnDeviceEdits, "a Writing Tools opt-in never enables the app's own rewrite")
    }

    func testRefreshPicksUpAManagedChangeAndNotifiesOnce() {
        let (policy, managed, _) = makePolicy()
        policy.setAssistanceEnabled(true)
        let seen = OSAllocatedUnfairLock<[PolicySnapshot]>(initialState: [])
        policy.observeChanges { snapshot in seen.withLock { $0.append(snapshot) } }
        managed.value = .forbidden
        policy.refresh()
        policy.refresh()
        XCTAssertEqual(seen.withLock { $0 }.map(\.assistance), [.managedOff])
    }

    func testRefreshPicksUpModelStateChanges() {
        let (policy, _, availability) = makePolicy(model: .downloading)
        policy.setAssistanceEnabled(true)
        XCTAssertEqual(policy.snapshot.assistance, .downloading)
        availability.value = .available
        policy.refresh()
        XCTAssertEqual(policy.snapshot.assistance, .ready)
    }

    func testTogglingNotifiesObserversWithTheNewState() {
        let (policy, _, _) = makePolicy()
        let seen = OSAllocatedUnfairLock<[AssistanceState]>(initialState: [])
        policy.observeChanges { snapshot in seen.withLock { $0.append(snapshot.assistance) } }
        policy.setAssistanceEnabled(true)
        policy.setAssistanceEnabled(true)
        policy.setAssistanceEnabled(false)
        XCTAssertEqual(seen.withLock { $0 }, [.ready, .off])
    }

    func testCurrentSnapshotReReadsTheManagedPreference() {
        let (policy, managed, _) = makePolicy()
        policy.setAssistanceEnabled(true)
        managed.value = .forbidden
        XCTAssertEqual(policy.currentSnapshot().assistance, .managedOff)
    }
}

final class PreferencesManagedPolicyReaderTests: XCTestCase {
    private func reader(forced: Bool, value: Bool?) -> PreferencesManagedPolicyReader {
        PreferencesManagedPolicyReader(isForced: { _ in forced }, value: { _ in value })
    }

    func testNotForcedIsNotManagedWhateverTheValue() {
        XCTAssertEqual(reader(forced: false, value: false).read(), .notManaged)
        XCTAssertEqual(reader(forced: false, value: nil).read(), .notManaged)
    }

    func testForcedFalseForbids() {
        XCTAssertEqual(reader(forced: true, value: false).read(), .forbidden)
    }

    func testForcedTrueAllows() {
        XCTAssertEqual(reader(forced: true, value: true).read(), .allowed)
    }

    func testForcedButMissingOrNonBooleanValueFailsClosed() {
        XCTAssertEqual(reader(forced: true, value: nil).read(), .forbidden)
    }

    func testReadsTheDocumentedKey() {
        let keys = OSAllocatedUnfairLock<Set<String>>(initialState: [])
        let reader = PreferencesManagedPolicyReader(
            isForced: { key in keys.withLock { _ = $0.insert(key) }; return false },
            value: { key in keys.withLock { _ = $0.insert(key) }; return nil })
        _ = reader.read()
        XCTAssertEqual(keys.withLock { $0 }, ["AllowWritingAssistance"])
        XCTAssertEqual(PreferencesManagedPolicyReader.key, "AllowWritingAssistance")
    }
}
