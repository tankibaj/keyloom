import CloudKit
import Foundation
import Security

// Opt-in private CloudKit probe. Nothing here runs at launch: the container is
// only touched from an explicit button press, with an identifier the human
// supplies for a test container that this build is signed for.

protocol CloudRecordStore {
    func accountIsAvailable() async throws -> Bool
    func save(recordName: String, payload: String) async throws
    func fetch(recordName: String) async throws -> String?
    func delete(recordName: String) async throws
}

struct CloudProbeStep: Equatable {
    let name: String
    let ok: Bool
    let detail: String
}

struct CloudProbeReport: Equatable {
    var recordName: String
    var steps: [CloudProbeStep] = []
    var passed: Bool { !steps.isEmpty && steps.allSatisfy(\.ok) }
}

/// Save, fetch, delete and read back one unique disposable record. The delete
/// always runs once a save was attempted, so a failure cannot leave the record behind.
struct CloudProbeRunner {
    static let payload = "keyloom-probe-synthetic"

    let store: CloudRecordStore
    var makeRecordName: () -> String = { "kl-probe-" + UUID().uuidString }

    func run() async -> CloudProbeReport {
        var report = CloudProbeReport(recordName: makeRecordName())
        func add(_ name: String, _ ok: Bool, _ detail: String = "") {
            report.steps.append(CloudProbeStep(name: name, ok: ok, detail: detail))
        }
        var saveAttempted = false
        do {
            guard try await store.accountIsAvailable() else {
                add("account", false, "iCloud account not available")
                return report
            }
            add("account", true)
            saveAttempted = true
            try await store.save(recordName: report.recordName, payload: Self.payload)
            add("save", true)
            let fetched = try await store.fetch(recordName: report.recordName)
            add("fetch", fetched == Self.payload, fetched == nil ? "record missing" : "")
        } catch {
            add("error", false, Self.describe(error))
        }
        if saveAttempted {
            do {
                try await store.delete(recordName: report.recordName)
                add("delete", true)
                let remaining = try await store.fetch(recordName: report.recordName)
                add("readBackAfterDelete", remaining == nil, remaining == nil ? "" : "record still present")
            } catch {
                add("cleanup", false, Self.describe(error))
            }
        }
        return report
    }

    /// Domain and code only; never record contents or identifiers.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}

enum CloudProvisioning {
    static func entitlement(_ name: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    }

    /// Why a live run is impossible, or nil when this build is signed for the container.
    static func blocker(
        containerID: String, lookup: (String) -> Any? = CloudProvisioning.entitlement
    ) -> String? {
        guard !containerID.isEmpty else { return "No container identifier supplied." }
        let containers = lookup("com.apple.developer.icloud-container-identifiers") as? [String]
        let services = lookup("com.apple.developer.icloud-services") as? [String]
        guard containers?.contains(containerID) == true, services?.contains("CloudKit") == true else {
            return "This build is not signed with CloudKit for that container (not provisioned)."
        }
        return nil
    }
}

final class CloudKitRecordStore: CloudRecordStore {
    private let container: CKContainer

    init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    private var database: CKDatabase { container.privateCloudDatabase }

    func accountIsAvailable() async throws -> Bool {
        try await container.accountStatus() == .available
    }

    func save(recordName: String, payload: String) async throws {
        let record = CKRecord(recordType: "KeyloomProbe", recordID: CKRecord.ID(recordName: recordName))
        record["payload"] = payload as CKRecordValue
        _ = try await database.save(record)
    }

    func fetch(recordName: String) async throws -> String? {
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: recordName))
            return record["payload"] as? String
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func delete(recordName: String) async throws {
        _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: recordName))
    }
}
