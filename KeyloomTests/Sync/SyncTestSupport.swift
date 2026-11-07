import CloudKit
import XCTest
@testable import Keyloom

/// An in-memory stand-in for the iCloud private database, one database per iCloud account. It keeps real
/// `CKRecord`s built by the production record mapping, hands out server tags like CloudKit (a save with a
/// stale or missing tag is refused with the server's record), and can be told to go offline, to refuse writes
/// for quota, or to change data as if another device had. Fetches replay every change since a token, including
/// the caller's own, as a real server would.
final class FakeCloud: @unchecked Sendable {
    private struct Server {
        var records: [UUID: CKRecord] = [:]
        var tags: [UUID: Int] = [:]
        var log: [(seq: Int, id: UUID)] = []
        var seq = 0
    }

    private let lock = NSLock()
    private var servers: [String: Server] = [:]
    private var offline = false
    private var recordLimit: Int?
    private let zone = CKRecordZone.ID(zoneName: SnippetRecord.zoneName, ownerName: CKCurrentUserDefaultName)

    var isOffline: Bool {
        get { lock.withLock { offline } }
        set { lock.withLock { offline = newValue } }
    }

    /// Writes that would create a record beyond this many are refused with quota exceeded.
    var maxRecordsPerAccount: Int? {
        get { lock.withLock { recordLimit } }
        set { lock.withLock { recordLimit = newValue } }
    }

    static func tagData(_ tag: Int) -> Data { Data("tag-\(tag)".utf8) }
    private static func tag(from data: Data?) -> Int? {
        data.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.hasPrefix("tag-") ? Int($0.dropFirst(4)) : nil }
    }

    func snippets(account: String) -> [UUID: Snippet] {
        lock.withLock {
            (servers[account]?.records ?? [:]).compactMapValues { try? SnippetRecord.snippet(from: $0) }
        }
    }

    func recordCount(account: String) -> Int { lock.withLock { servers[account]?.records.count ?? 0 } }

    /// What another device would do: remove a record on the server.
    func deleteExternally(account: String, id: UUID) {
        lock.withLock {
            var server = servers[account] ?? Server()
            guard server.records.removeValue(forKey: id) != nil else { return }
            server.tags[id] = nil
            server.seq += 1
            server.log.append((server.seq, id))
            servers[account] = server
        }
    }

    /// What another device would do: store a record as is (an optionally malformed one).
    func putExternally(account: String, record: CKRecord) {
        lock.withLock {
            var server = servers[account] ?? Server()
            guard let id = UUID(uuidString: record.recordID.recordName) else { return }
            server.records[id] = record
            server.seq += 1
            server.tags[id] = server.seq
            server.log.append((server.seq, id))
            servers[account] = server
        }
    }

    func recordID(_ id: UUID) -> CKRecord.ID { SnippetRecord.recordID(id, zoneID: zone) }

    func fetch(account: String, since token: Int) throws -> (changes: [RemoteChange], unreadable: Int, token: Int) {
        try lock.withLock {
            if offline { throw SyncFailure(kind: .networkUnavailable) }
            let server = servers[account] ?? Server()
            var latest: [UUID] = []
            for entry in server.log where entry.seq > token {
                latest.removeAll { $0 == entry.id }
                latest.append(entry.id)
            }
            var changes: [RemoteChange] = []
            var unreadable = 0
            for id in latest {
                guard let record = server.records[id] else {
                    changes.append(.delete(id))
                    continue
                }
                do {
                    changes.append(.upsert(try SnippetRecord.snippet(from: record), systemFields: Self.tagData(server.tags[id] ?? 0)))
                } catch {
                    unreadable += 1
                }
            }
            return (changes, unreadable, server.seq)
        }
    }

    func apply(_ change: OutgoingChange, account: String) -> SendOutcome {
        lock.withLock {
            var server = servers[account] ?? Server()
            defer { servers[account] = server }
            let serverTag = server.tags[change.recordID]
            switch change.payload {
            case .save(let snippet):
                let sentTag = Self.tag(from: change.systemFields)
                if let serverTag, sentTag != serverTag {
                    let current = (try? SnippetRecord.snippet(from: server.records[change.recordID]!))
                    return current.map { .serverHasNewer(.upsert($0, systemFields: Self.tagData(serverTag))) } ?? .failed(.other(code: -1))
                }
                if serverTag == nil, sentTag != nil { return .serverHasNewer(.delete(change.recordID)) }
                if serverTag == nil, let recordLimit, server.records.count >= recordLimit { return .failed(.quotaExceeded) }
                let record = CKRecord(recordType: SnippetRecord.recordType, recordID: recordID(change.recordID))
                do { try SnippetRecord.fill(record, from: snippet) } catch { return .failed(.recordTooLarge) }
                server.records[change.recordID] = record
                server.seq += 1
                server.tags[change.recordID] = server.seq
                server.log.append((server.seq, change.recordID))
                return .saved(systemFields: Self.tagData(server.seq))
            case .delete:
                guard serverTag != nil else { return .deleted }
                server.records[change.recordID] = nil
                server.tags[change.recordID] = nil
                server.seq += 1
                server.log.append((server.seq, change.recordID))
                return .deleted
            }
        }
    }
}

/// A fake `SyncEngineAdapter` for one Mac: it fetches from and sends to a `FakeCloud` when `syncNow()` is
/// called, delivering results to the controller's session like CKSyncEngine would, in order.
final class FakeEngine: SyncEngineAdapter, @unchecked Sendable {
    struct Crash: Error {}

    private let lock = NSLock()
    private let cloud: FakeCloud
    private var currentAccount: CloudAccountStatus
    private var current: SyncSession?
    private var retired: SyncSession?
    private var token = 0
    private var counters = (starts: 0, stops: 0, syncs: 0, accountChecks: 0)
    private var states: [Data?] = []
    private var crashNext = false
    private var failingSends: SyncFailureKind?

    init(cloud: FakeCloud, account: CloudAccountStatus) {
        self.cloud = cloud
        currentAccount = account
    }

    var account: CloudAccountStatus {
        get { lock.withLock { currentAccount } }
        set { lock.withLock { currentAccount = newValue } }
    }

    var startCount: Int { lock.withLock { counters.starts } }
    var stopCount: Int { lock.withLock { counters.stops } }
    var syncCount: Int { lock.withLock { counters.syncs } }
    var accountChecks: Int { lock.withLock { counters.accountChecks } }
    var startStates: [Data?] { lock.withLock { states } }
    /// The session the controller handed over last, even after it was stopped: what a late callback would hold.
    var lastSession: SyncSession? { lock.withLock { current ?? retired } }

    /// The next send stores its records in the cloud and then the app "crashes" before hearing back.
    func crashAfterNextCloudCommit() { lock.withLock { crashNext = true } }
    func failSends(with kind: SyncFailureKind?) { lock.withLock { failingSends = kind } }

    func accountStatus() async -> CloudAccountStatus {
        lock.withLock {
            counters.accountChecks += 1
            return currentAccount
        }
    }

    func start(session: SyncSession, state: Data?) async throws {
        lock.withLock {
            counters.starts += 1
            states.append(state)
            current = session
            token = state.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init) ?? 0
        }
    }

    func stop() async {
        lock.withLock {
            counters.stops += 1
            retired = current
            current = nil
        }
    }

    func syncNow() async throws {
        let (session, account, since) = lock.withLock { () -> (SyncSession?, CloudAccountStatus, Int) in
            counters.syncs += 1
            return (current, currentAccount, token)
        }
        guard let session else { throw SyncFailure(kind: .other(code: -2)) }
        guard case .available(let id) = account, id == session.account else {
            await session.deliver(.accountChanged(account))
            return
        }
        let fetched = try cloud.fetch(account: id, since: since)
        await session.deliver(.fetched(fetched.changes, unreadable: fetched.unreadable))
        lock.withLock { token = fetched.token }
        await session.deliver(.stateUpdated(Data("\(fetched.token)".utf8)))

        // Like the production adapter, silently leave out a snippet whose record cannot be built.
        let batch = await session.nextOutgoing(limit: 100).filter { change in
            guard case .save(let snippet) = change.payload else { return true }
            let scratch = CKRecord(recordType: SnippetRecord.recordType, recordID: SnippetRecord.recordID(change.recordID))
            return (try? SnippetRecord.fill(scratch, from: snippet)) != nil
        }
        guard !batch.isEmpty else { return }
        if cloud.isOffline { throw SyncFailure(kind: .networkUnavailable) }
        let failing = lock.withLock { failingSends }
        let results = batch.map { change -> SendResult in
            var sentRevision: Int?
            if case .save(let snippet) = change.payload { sentRevision = snippet.revision }
            return SendResult(recordID: change.recordID, outcome: failing.map { .failed($0) } ?? cloud.apply(change, account: id),
                              sentRevision: sentRevision)
        }
        let crash = lock.withLock { () -> Bool in
            defer { crashNext = false }
            return crashNext
        }
        if crash { throw Crash() }
        await session.deliver(.sent(results))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

/// Lets a test hold a callback in flight and release it on demand, without sleeping.
actor Gate {
    private var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    var hasEntered: Bool { entered }

    func pass() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

/// One Mac in a sync test: a real library file, a real controller and preference, and a fake engine.
final class SyncDevice: @unchecked Sendable {
    let directory: URL
    let cloud: FakeCloud
    let engine: FakeEngine
    let clock: TestClock
    let ids: SequentialIDs
    let defaults: UserDefaults
    let libraryReloads = Counter()
    private(set) var store: SnippetStore
    private(set) var controller: SyncController

    private static func open(_ directory: URL, clock: TestClock, ids: SequentialIDs) throws -> SnippetStore {
        try SnippetStore(url: directory.appendingPathComponent("keyloom.sqlite"),
                         backupDirectory: directory.appendingPathComponent("backups"),
                         now: { [clock] in clock.now }, makeID: { [ids] in ids.next() })
    }

    init(directory: URL, cloud: FakeCloud, account: CloudAccountStatus, clock: TestClock, idStart: Int, suite: String) throws {
        self.directory = directory
        self.cloud = cloud
        self.clock = clock
        ids = SequentialIDs(startingAt: idStart)
        engine = FakeEngine(cloud: cloud, account: account)
        defaults = UserDefaults(suiteName: suite)!
        store = try Self.open(directory, clock: clock, ids: ids)
        controller = SyncDevice.makeController(store: store, engine: engine, defaults: defaults, clock: clock, reloads: libraryReloads)
    }

    private static func makeController(store: SnippetStore, engine: FakeEngine, defaults: UserDefaults, clock: TestClock,
                                       reloads: Counter, onChange: (@Sendable () async -> Void)? = nil) -> SyncController {
        SyncController(store: store, adapter: engine, preference: SyncPreference(defaults: defaults),
                       onLibraryChanged: { reloads.increment(); await onChange?() }, now: { clock.now })
    }

    /// Replaces the controller with one whose library-changed callback runs `onChange` (to hold it in flight).
    func useController(onLibraryChanged onChange: @escaping @Sendable () async -> Void) {
        controller = Self.makeController(store: store, engine: engine, defaults: defaults, clock: clock,
                                         reloads: libraryReloads, onChange: onChange)
    }

    func enableSync() async { await controller.setEnabled(true) }
    func sync() async { await controller.syncNow() }

    /// Quits and reopens the app on the same files: a clean quit stops sync first, a crash does not.
    func relaunch(crash: Bool = false) async throws {
        if !crash { await controller.shutdown() }
        await store.close()
        store = try Self.open(directory, clock: clock, ids: ids)
        controller = Self.makeController(store: store, engine: engine, defaults: defaults, clock: clock, reloads: libraryReloads)
        await controller.launch()
    }
}

class SyncTestCase: StoreTestCase {
    let cloud = FakeCloud()

    func makeDevice(account: CloudAccountStatus = .available(account: "icloud:A"), idStart: Int = 10_000) throws -> SyncDevice {
        let suite = "keyloom.tests.sync.\(UUID().uuidString)"
        let device = try SyncDevice(directory: try makeDirectory(), cloud: cloud, account: account, clock: clock,
                                    idStart: idStart, suite: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return device
    }

    /// Syncs `devices` in turn, three times, so each sees what the others pushed and what they pushed in reply.
    func settle(_ devices: SyncDevice...) async {
        for _ in 0..<3 {
            for device in devices { await device.sync() }
        }
    }
}
