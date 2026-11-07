import CloudKit
import Foundation
import Security

/// The production `SyncEngineAdapter`: a thin translation between `CKSyncEngine` and `SyncSession`. All
/// decisions (reconciliation, queueing, acknowledgement, account isolation) live in `SyncController` and the
/// store; this type only moves records and events across the process boundary.
///
/// NOT VERIFIED: it compiles but has never run against CloudKit, because that needs a build signed with the
/// iCloud entitlement and a test account (see `Feasibility/CloudKit.entitlements.example`). Every behavior
/// above this layer is tested against `FakeEngine`.
///
/// - CloudKit is touched only when the user turned sync on and the build carries the CloudKit entitlement; an
///   unsigned build reports `.buildNotProvisioned` instead of crashing in `CKContainer`.
/// - `stop()` never deletes records or zones: it cancels operations and drops the engine.
/// - The outbox is the source of truth for what to send. Before each send the engine's pending list is brought
///   in line with it, and every record the engine asks for is built from the outbox snapshot, so a stale pending
///   entry sends nothing.
/// - Events are forwarded without interpretation. An account change is forwarded from a separate task, because
///   the controller answers it by replacing this engine and must not do that inside the engine's own callback.
final class CKSyncEngineAdapter: SyncEngineAdapter, CKSyncEngineDelegate, @unchecked Sendable {
    private struct Running {
        let engine: CKSyncEngine
        let session: SyncSession
    }

    private let containerIdentifier: String?
    private let lock = NSLock()
    private var running: Running?

    /// `nil` uses the app's default (first entitled) container.
    init(containerIdentifier: String? = nil) { self.containerIdentifier = containerIdentifier }

    // MARK: SyncEngineAdapter

    func accountStatus() async -> CloudAccountStatus {
        guard Self.hasCloudKitEntitlement else { return .buildNotProvisioned }
        let container = makeContainer()
        do {
            switch try await container.accountStatus() {
            case .available: return .available(account: "icloud:" + (try await container.userRecordID()).recordName)
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .couldNotDetermine
            @unknown default: return .couldNotDetermine
            }
        } catch {
            return .couldNotDetermine
        }
    }

    func start(session: SyncSession, state: Data?) async throws {
        // A state this build cannot read is dropped: the engine refetches and every apply is idempotent.
        let serialization = state.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let configuration = CKSyncEngine.Configuration(database: makeContainer().privateCloudDatabase,
                                                       stateSerialization: serialization, delegate: self)
        let engine = CKSyncEngine(configuration)
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SnippetRecord.zoneID))])
        lock.withLock { running = Running(engine: engine, session: session) }
    }

    func stop() async {
        guard let engine = lock.withLock({ () -> CKSyncEngine? in
            defer { running = nil }
            return running?.engine
        }) else { return }
        await engine.cancelOperations()
    }

    func syncNow() async throws {
        guard let current = lock.withLock({ running }) else { throw SyncFailure(kind: .other(code: -1)) }
        await schedule(current.session, in: current.engine)
        do {
            try await current.engine.fetchChanges()
            try await current.engine.sendChanges()
        } catch {
            throw SyncFailure(kind: Self.failureKind(of: error))
        }
    }

    /// Fires whenever macOS reports an iCloud account change; feed it to `SyncController.accountMayHaveChanged()`.
    static func accountChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            nonisolated(unsafe) let observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil,
                                                                                      queue: nil) { _ in continuation.yield() }
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(observer) }
        }
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let session = session(for: syncEngine) else { return }
        switch event {
        case .stateUpdate(let update):
            if let state = try? JSONEncoder().encode(update.stateSerialization) { await session.deliver(.stateUpdated(state)) }
        case .accountChange:
            Task { await session.deliver(.accountChanged(await self.accountStatus())) }
        case .fetchedDatabaseChanges(let changes):
            // The zone is gone (the user erased iCloud data, or another Mac did). The local library stays; the
            // controller forgets this account's ancestors so everything uploads again.
            if changes.deletions.contains(where: { $0.zoneID == SnippetRecord.zoneID }) { await session.deliver(.remoteDataReset) }
        case .fetchedRecordZoneChanges(let changes):
            await session.deliver(Self.fetched(changes))
        case .sentRecordZoneChanges(let sent):
            await session.deliver(.sent(Self.results(of: sent)))
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let session = session(for: syncEngine) else { return nil }
        let outgoing = await session.nextOutgoing(limit: Self.batchLimit)
        await schedule(outgoing, in: syncEngine)
        let byName = Dictionary(outgoing.map { ($0.recordID.uuidString, $0) }, uniquingKeysWith: { _, newest in newest })
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            guard let change = byName[recordID.recordName], case .save(let snippet) = change.payload else { return nil }
            let record = SnippetRecord.record(for: change.recordID, systemFields: change.systemFields)
            do {
                try SnippetRecord.fill(record, from: snippet)
                return record
            } catch {
                return nil
            }
        }
    }

    // MARK: Private

    private static let batchLimit = 200

    private static var hasCloudKitEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String]
        else { return false }
        return services.contains("CloudKit")
    }

    private func makeContainer() -> CKContainer {
        containerIdentifier.map(CKContainer.init(identifier:)) ?? CKContainer.default()
    }

    private func session(for engine: CKSyncEngine) -> SyncSession? {
        lock.withLock { running.flatMap { $0.engine === engine ? $0.session : nil } }
    }

    private func schedule(_ session: SyncSession, in engine: CKSyncEngine) async {
        await schedule(await session.nextOutgoing(limit: Self.batchLimit), in: engine)
    }

    /// Makes the engine's pending list include everything the outbox wants sent, replacing a pending save with
    /// a pending delete (or the reverse) when the record's newest local state changed kind.
    private func schedule(_ outgoing: [OutgoingChange], in engine: CKSyncEngine) async {
        var wanted: [CKSyncEngine.PendingRecordZoneChange] = []
        var stale: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in outgoing {
            let id = SnippetRecord.recordID(change.recordID)
            switch change.payload {
            case .save:
                wanted.append(.saveRecord(id))
                stale.append(.deleteRecord(id))
            case .delete:
                wanted.append(.deleteRecord(id))
                stale.append(.saveRecord(id))
            }
        }
        engine.state.remove(pendingRecordZoneChanges: stale)
        engine.state.add(pendingRecordZoneChanges: wanted)
    }

    private static func fetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) -> SyncEngineEvent {
        var remote: [RemoteChange] = []
        var unreadable = 0
        var newerSchema: [UUID: Int] = [:]
        for modification in changes.modifications {
            do {
                remote.append(.upsert(try SnippetRecord.snippet(from: modification.record),
                                      systemFields: SnippetRecord.archivedSystemFields(of: modification.record)))
            } catch {
                unreadable += 1
                if case SnippetRecordError.unsupportedSchema(let found) = error, let id = UUID(uuidString: modification.record.recordID.recordName) {
                    newerSchema[id] = found
                }
            }
        }
        for deletion in changes.deletions {
            if let id = UUID(uuidString: deletion.recordID.recordName) { remote.append(.delete(id)) }
        }
        return .fetched(remote, unreadable: unreadable, newerSchema: newerSchema)
    }

    private static func results(of sent: CKSyncEngine.Event.SentRecordZoneChanges) -> [SendResult] {
        var results: [SendResult] = []
        for record in sent.savedRecords {
            guard let id = UUID(uuidString: record.recordID.recordName) else { continue }
            results.append(SendResult(recordID: id, outcome: .saved(systemFields: SnippetRecord.archivedSystemFields(of: record)),
                                      sentRevision: (try? SnippetRecord.snippet(from: record))?.revision))
        }
        for failure in sent.failedRecordSaves {
            guard let id = UUID(uuidString: failure.record.recordID.recordName) else { continue }
            results.append(SendResult(recordID: id, outcome: saveFailure(failure.error, id: id)))
        }
        for recordID in sent.deletedRecordIDs {
            if let id = UUID(uuidString: recordID.recordName) { results.append(SendResult(recordID: id, outcome: .deleted)) }
        }
        for (recordID, error) in sent.failedRecordDeletes {
            guard let id = UUID(uuidString: recordID.recordName) else { continue }
            results.append(SendResult(recordID: id, outcome: error.code == .unknownItem ? .deleted : .failed(failureKind(of: error))))
        }
        return results
    }

    /// A refused save either reports what the cloud holds (reconciled like any remote change) or a failure.
    // TODO(keyloom-wp5): a .zoneNotFound failure (the zone was erased) is only reported as an error today; recreate
    // the zone and re-send, when live CloudKit testing is possible (needs the iCloud entitlement and a test account).
    private static func saveFailure(_ error: CKError, id: UUID) -> SendOutcome {
        switch error.code {
        case .serverRecordChanged:
            guard let server = error.serverRecord, let snippet = try? SnippetRecord.snippet(from: server) else {
                return .failed(failureKind(of: error))
            }
            return .serverHasNewer(.upsert(snippet, systemFields: SnippetRecord.archivedSystemFields(of: server)))
        case .unknownItem:
            // Saved with a server tag, but the cloud no longer has the record: it was deleted elsewhere.
            return .serverHasNewer(.delete(id))
        default:
            return .failed(failureKind(of: error))
        }
    }

    static func failureKind(of error: Error) -> SyncFailureKind {
        guard let cloudError = error as? CKError else { return .other(code: (error as NSError).code) }
        switch cloudError.code {
        case .quotaExceeded: return .quotaExceeded
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy: return .networkUnavailable
        case .notAuthenticated: return .notAuthenticated
        case .limitExceeded: return .recordTooLarge
        default: return .other(code: cloudError.code.rawValue)
        }
    }
}
