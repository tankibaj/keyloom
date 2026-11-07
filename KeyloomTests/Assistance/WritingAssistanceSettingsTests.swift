import SwiftUI
import XCTest
@testable import Keyloom

@MainActor
final class WritingAssistanceSettingsTests: XCTestCase {
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

    private func makeModel(managed: ManagedAssistancePolicy = .notManaged, model: ModelAvailability = .available)
        -> (WritingAssistanceSettingsModel, WritingAssistancePolicy) {
        let policy = WritingAssistancePolicy(defaults: defaults, managed: FakeManagedPolicy(managed),
                                             availability: FakeAvailability(model), locale: Locale(identifier: "en_US"))
        return (WritingAssistanceSettingsModel(policy: policy), policy)
    }

    func testTogglesWriteThroughToThePolicy() {
        let (model, policy) = makeModel()
        XCTAssertFalse(model.assistanceEnabled)
        XCTAssertFalse(model.systemWritingToolsEnabled)
        model.assistanceEnabled = true
        model.systemWritingToolsEnabled = true
        XCTAssertTrue(policy.isAssistanceEnabled)
        XCTAssertTrue(policy.isSystemWritingToolsEnabled)
    }

    func testManagedOffLocksBothTogglesAndSaysTheOrganizationChoseIt() {
        let (model, _) = makeModel(managed: .forbidden)
        XCTAssertTrue(model.togglesLocked)
        XCTAssertTrue(model.assistanceStatus.localizedCaseInsensitiveContains("organization"))
        XCTAssertTrue(model.writingToolsStatus.localizedCaseInsensitiveContains("organization"))
    }

    func testTogglesAreFreeWhenNotManaged() {
        let (model, _) = makeModel()
        XCTAssertFalse(model.togglesLocked)
    }

    func testStatusTextIsDistinctForEveryState() {
        let states: [AssistanceState] = [.off, .ready, .unavailable(.deviceNotEligible),
                                         .unavailable(.appleIntelligenceNotEnabled), .unavailable(.unspecified),
                                         .downloading, .unsupportedLanguage, .managedOff]
        let texts = states.map { AssistanceCopy.assistanceStatus($0) }
        XCTAssertEqual(Set(texts).count, states.count)
        XCTAssertTrue(texts.allSatisfy { !$0.isEmpty })
    }

    func testUnavailableTextNeverBlamesAnAdministrator() {
        for reason in [UnavailableReason.deviceNotEligible, .appleIntelligenceNotEnabled, .unspecified] {
            let text = AssistanceCopy.assistanceStatus(.unavailable(reason)).lowercased()
            for word in ["administrator", "restrict", "organization", "managed", "policy", " it "] {
                XCTAssertFalse(text.contains(word), "\(reason): must not infer an IT restriction (\(word))")
            }
        }
    }

    func testDisclosureNamesAppleAndExternalServices() {
        let text = AssistanceCopy.writingToolsDisclosure
        XCTAssertTrue(text.contains("Apple"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("external"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("send"))
    }

    func testStatusFollowsAnOSChange() {
        let (model, policy) = makeModel(model: .downloading)
        model.assistanceEnabled = true
        XCTAssertEqual(model.assistanceStatus, AssistanceCopy.assistanceStatus(.downloading))
        XCTAssertFalse(policy.snapshot.permitsOnDeviceEdits)
    }

    func testViewRendersInAHostingView() {
        let (model, _) = makeModel()
        let host = NSHostingView(rootView: WritingAssistanceSettingsView(model: model))
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
