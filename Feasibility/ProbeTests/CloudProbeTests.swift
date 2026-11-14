import XCTest

private struct StoreFailure: Error {}

private final class FakeStore: CloudRecordStore {
    var accountAvailable = true
    var failSave = false
    var failFetchAfterSave = false
    private(set) var calls: [String] = []
    private var records: [String: String] = [:]

    func accountIsAvailable() async throws -> Bool {
        calls.append("account")
        return accountAvailable
    }

    func save(recordName: String, payload: String) async throws {
        calls.append("save")
        if failSave { throw StoreFailure() }
        records[recordName] = payload
    }

    func fetch(recordName: String) async throws -> String? {
        calls.append("fetch")
        if failFetchAfterSave && records[recordName] != nil { throw StoreFailure() }
        return records[recordName]
    }

    func delete(recordName: String) async throws {
        calls.append("delete")
        records[recordName] = nil
    }

    var isEmpty: Bool { records.isEmpty }
}

final class CloudProbeTests: XCTestCase {
    func testSavesFetchesDeletesAndReadsBackOneRecord() async {
        let store = FakeStore()
        let report = await CloudProbeRunner(store: store).run()
        XCTAssertTrue(report.passed)
        XCTAssertEqual(store.calls, ["account", "save", "fetch", "delete", "fetch"])
        XCTAssertTrue(store.isEmpty)
    }

    func testFetchFailureStillDeletesTheRecord() async {
        let store = FakeStore()
        store.failFetchAfterSave = true
        let report = await CloudProbeRunner(store: store).run()
        XCTAssertFalse(report.passed)
        XCTAssertTrue(store.calls.contains("delete"))
        XCTAssertTrue(store.isEmpty)
    }

    func testSaveFailureStillAttemptsCleanup() async {
        let store = FakeStore()
        store.failSave = true
        let report = await CloudProbeRunner(store: store).run()
        XCTAssertFalse(report.passed)
        XCTAssertTrue(store.calls.contains("delete"))
    }

    func testUnavailableAccountStopsBeforeAnyWrite() async {
        let store = FakeStore()
        store.accountAvailable = false
        let report = await CloudProbeRunner(store: store).run()
        XCTAssertFalse(report.passed)
        XCTAssertEqual(store.calls, ["account"])
    }

    func testRecordNamesAreUniqueAndPrefixed() async {
        let first = await CloudProbeRunner(store: FakeStore()).run()
        let second = await CloudProbeRunner(store: FakeStore()).run()
        XCTAssertTrue(first.recordName.hasPrefix("kl-probe-"))
        XCTAssertNotEqual(first.recordName, second.recordName)
    }

    func testLiveRunIsBlockedUnlessSignedForTheSuppliedContainer() {
        XCTAssertNotNil(CloudProvisioning.blocker(containerID: "", lookup: { _ in nil }))
        XCTAssertNotNil(CloudProvisioning.blocker(containerID: "iCloud.example.test", lookup: { _ in nil }))
        let signed: (String) -> Any? = {
            $0 == "com.apple.developer.icloud-container-identifiers" ? ["iCloud.example.test"] : ["CloudKit"]
        }
        XCTAssertNil(CloudProvisioning.blocker(containerID: "iCloud.example.test", lookup: signed))
        XCTAssertNotNil(CloudProvisioning.blocker(containerID: "iCloud.other", lookup: signed))
    }
}
