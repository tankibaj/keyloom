import Foundation

/// One engine run's handle to the controller. The controller recognizes a session by identity: once it stopped
/// the run (switch off, sign-out, another account), everything the session says is dropped, so a late callback
/// can neither write to the library nor touch another account's data.
final class SyncSession: Sendable {
    let account: String
    private let controller: SyncController

    fileprivate init(account: String, controller: SyncController) {
        self.account = account
        self.controller = controller
    }

    func deliver(_ event: SyncEngineEvent) async { await controller.deliver(event, from: self) }

    /// The next changes to push. They stay queued until a `.sent` result acknowledges them.
    func nextOutgoing(limit: Int) async -> [OutgoingChange] { await controller.outgoing(limit: limit, for: self) }
}

/// Runs iCloud sync for this Mac, only while the user's switch is on.
///
/// - Off (the default): nothing touches the cloud. Turning it off stops the engine and keeps the local library,
///   the queue, the engine state and every iCloud record; edits made meanwhile are journaled locally and
///   reconciled when it is turned on again.
/// - Local use never waits on sync: this actor owns no library data, the store is its own actor, and every
///   sync failure ends in a status, never in an error to local callers.
/// - Fencing: each start creates a `SyncSession`. Stopping clears it first, so later callbacks are ignored,
///   then waits for callbacks already running to finish (`drain`), so after `setEnabled(false)` returns
///   nothing more is written on behalf of that session. Every store call names the session's account; there is
///   no "current account" a late callback could pick up.
/// - Accounts are isolated: the queue, ancestors and engine state are per account, and a snippet synced with
///   one account is never uploaded to another (see `SnippetStore.prepareSync`).
/// - Never logs or reports snippet text; statuses and problems carry codes only.
/// - `onLibraryChanged` runs while a callback is in flight, so it must not call back into this controller
///   (stopping would wait for itself); reload the library and return.
actor SyncController {
    private enum FollowUp {
        case syncAgain
        case accountChanged(CloudAccountStatus)
        case signedOut
    }

    private static let maxUnansweredPerRecord = 8

    private let store: SnippetStore
    private let adapter: any SyncEngineAdapter
    private let preference: SyncPreference
    private let onLibraryChanged: @Sendable () async -> Void
    private let now: @Sendable () -> Date

    private(set) var status: SyncStatus = .off {
        didSet { if status != oldValue { subscribers.values.forEach { $0.yield(status) } } }
    }
    /// Callbacks dropped because their session had been stopped.
    private(set) var ignoredCallbackCount = 0
    /// Remote records this build could not read or that failed validation; left untouched in iCloud.
    private(set) var skippedRemoteRecords = 0
    /// True while `setEnabled(false)` or an account change is waiting for running callbacks to finish.
    private(set) var isDraining = false

    private var session: SyncSession?
    private var syncingSession: SyncSession?
    private var syncRequested = false
    private var starting = false
    /// Bumped whenever a session starts or stops, so a stop that was overtaken by a newer start knows it.
    private var generation = 0
    /// A remote change could not be stored (a transient store error): the engine's token must not move past it,
    /// and the session restarts from the last saved state at the next sync so the change is fetched again.
    private var replayNeeded = false
    private var inFlight = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Changes handed to the engine and not yet answered, per record; an answer names the revision it sent.
    private var sentBatch: [UUID: [OutgoingChange]] = [:]
    private var quotaHit = false
    private var problem: SyncProblem?
    private var subscribers: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]

    init(store: SnippetStore, adapter: any SyncEngineAdapter, preference: SyncPreference = SyncPreference(),
         onLibraryChanged: @escaping @Sendable () async -> Void = {}, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.adapter = adapter
        self.preference = preference
        self.onLibraryChanged = onLibraryChanged
        self.now = now
    }

    // MARK: Public

    /// Status changes, starting with the current one. Safe to iterate from the UI.
    func statusUpdates() -> AsyncStream<SyncStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: SyncStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        continuation.yield(status)
        return stream
    }

    /// Snippets sync turned off because another snippet holds their keyword, for a notice.
    func keywordConflictCount() async -> Int {
        (try? await store.keywordConflictDisabledIDs().count) ?? 0
    }

    /// Local changes waiting to be uploaded for the current (or last) account.
    func pendingChangeCount() async -> Int {
        let account = session?.account ?? SnippetStore.localSyncAccount
        return (try? await store.pendingCount(account: account)) ?? 0
    }

    /// At app launch: resumes sync if the saved switch is on, else stays off without touching the cloud.
    func launch() async {
        if preference.isEnabled { await start() } else { status = .off }
    }

    /// The user flipped the switch. Saved immediately, so a crash right after cannot undo the choice.
    func setEnabled(_ enabled: Bool) async {
        preference.isEnabled = enabled
        if enabled {
            await start()
        } else {
            await stopSession()
            status = .off
        }
    }

    /// Fetch remote changes and send queued ones. Starts sync first when the switch is on but nothing is running
    /// (it stopped for an account problem, or a stored change must be replayed).
    func syncNow() async {
        guard preference.isEnabled else { return }
        guard let session else {
            await start()
            return
        }
        if replayNeeded {
            await stopSession()
            await start()
            return
        }
        await runSync(session)
    }

    /// Call after a local mutation committed, so the queue is sent without waiting for the next trigger.
    func localChangesCommitted() async { await syncNow() }

    /// Call when macOS reports an iCloud account change (`CKAccountChanged`) or the app becomes active.
    func accountMayHaveChanged() async {
        guard preference.isEnabled else { return }
        let cloud = await adapter.accountStatus()
        guard preference.isEnabled else { return }
        if let session, case .available(let account) = cloud, account == session.account { return }
        await stopSession()
        // A newer start may have run while the stop waited; it owns the session now.
        guard session == nil, preference.isEnabled else { return }
        await startFor(cloud)
    }

    /// The app is quitting: stop the engine, keep the saved switch.
    func shutdown() async {
        await stopSession()
        status = .off
    }

    // MARK: Starting and stopping

    private func start() async {
        guard preference.isEnabled, session == nil, !starting else { return }
        starting = true
        defer { starting = false }
        status = .checkingAccount
        let cloud = await adapter.accountStatus()
        guard preference.isEnabled, session == nil else { return }
        await startFor(cloud)
    }

    private func startFor(_ cloud: CloudAccountStatus) async {
        switch cloud {
        case .noAccount: status = .signedOut
        case .restricted: status = .unavailable(.restricted)
        case .temporarilyUnavailable, .couldNotDetermine: status = .unavailable(.temporarilyUnavailable)
        case .buildNotProvisioned: status = .unavailable(.buildNotProvisioned)
        case .available(let account): await begin(account: account)
        }
    }

    private func begin(account: String) async {
        let session = SyncSession(account: account, controller: self)
        self.session = session
        generation += 1
        replayNeeded = false
        sentBatch = [:]
        status = .syncing
        let state: Data?
        var reenabledAtStart = false
        do {
            try await store.setSyncAccount(account)
            reenabledAtStart = try await store.prepareSync(account: account).reenabled
            state = try await store.syncEngineState(account: account)
        } catch {
            await abandon(session, because: .localStorage)
            return
        }
        guard self.session === session else { return }
        // The library loaded before sync started; a snippet turned back on by preparing must reach it.
        if reenabledAtStart { await onLibraryChanged() }
        do {
            try await adapter.start(session: session, state: state)
        } catch {
            await abandon(session, because: .unexpected(code: 0))
            return
        }
        await runSync(session)
    }

    private func abandon(_ session: SyncSession, because problem: SyncProblem) async {
        guard self.session === session else { return }
        await stopSession()
        status = .failed(problem)
    }

    /// Fences the session first, then lets the adapter stop, then waits for callbacks already running.
    private func stopSession() async {
        guard session != nil else { return }
        session = nil
        generation += 1
        let stopped = generation
        sentBatch = [:]
        await adapter.stop()
        await drain()
        // Edits from now on are journaled locally and adopted when sync starts again; but not if a newer session
        // started while this one drained, which owns the journal account now.
        // `local` is a valid account name, so this cannot throw.
        if session == nil, generation == stopped { try? await store.setSyncAccount(SnippetStore.localSyncAccount) }
    }

    private func drain() async {
        guard inFlight > 0 else { return }
        isDraining = true
        await withCheckedContinuation { drainWaiters.append($0) }
        isDraining = false
    }

    private func leaveCallback() {
        inFlight -= 1
        guard inFlight == 0 else { return }
        let waiters = drainWaiters
        drainWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    // MARK: Syncing

    private func runSync(_ session: SyncSession) async {
        guard self.session === session else { return }
        if syncingSession === session {
            syncRequested = true
            return
        }
        syncingSession = session
        defer { if syncingSession === session { syncingSession = nil } }
        repeat {
            syncRequested = false
            quotaHit = false
            problem = nil
            status = .syncing
            do {
                try await adapter.syncNow()
            } catch let failure as SyncFailure {
                await handle(failure, in: session)
                return
            } catch {
                if self.session === session { status = .failed(.unexpected(code: 0)) }
                return
            }
            guard self.session === session else { return }
            if quotaHit {
                status = .quotaExceeded
            } else if let problem {
                status = .failed(problem)
            } else {
                status = .upToDate(lastSyncedAt: now())
            }
        } while syncRequested && self.session === session
    }

    private func handle(_ failure: SyncFailure, in session: SyncSession) async {
        guard self.session === session else { return }
        switch failure.kind {
        case .quotaExceeded: status = .quotaExceeded
        case .networkUnavailable: status = .failed(.network)
        case .recordTooLarge: status = .failed(.recordTooLarge)
        case .other(let code): status = .failed(.unexpected(code: code))
        case .notAuthenticated:
            await stopSession()
            status = .signedOut
        }
    }

    // MARK: Callbacks from a session

    fileprivate func deliver(_ event: SyncEngineEvent, from session: SyncSession) async {
        guard session === self.session else {
            ignoredCallbackCount += 1
            return
        }
        inFlight += 1
        let followUp = await handle(event, from: session)
        leaveCallback()
        guard let followUp, session === self.session else { return }
        switch followUp {
        case .syncAgain: await runSync(session)
        case .signedOut:
            await stopSession()
            status = .signedOut
        case .accountChanged(let cloud):
            await stopSession()
            if preference.isEnabled, self.session == nil { await startFor(cloud) }
        }
    }

    fileprivate func outgoing(limit: Int, for session: SyncSession) async -> [OutgoingChange] {
        guard session === self.session else {
            ignoredCallbackCount += 1
            return []
        }
        inFlight += 1
        defer { leaveCallback() }
        let changes: [OutgoingChange]
        do {
            let batch = try await store.nextOutgoingBatch(account: session.account, limit: limit)
            changes = batch.changes
            if batch.libraryChanged { await onLibraryChanged() }
        } catch {
            problem = .localStorage
            return []
        }
        guard session === self.session else { return [] }
        let sendable = await withoutOversized(changes, account: session.account)
        for change in sendable where !(sentBatch[change.recordID] ?? []).contains(change) {
            sentBatch[change.recordID] = Array(((sentBatch[change.recordID] ?? []) + [change]).suffix(Self.maxUnansweredPerRecord))
        }
        return sendable
    }

    /// A snippet CloudKit would refuse for size is never handed to the engine, which would drop it silently: it
    /// counts as a failed attempt (kept queued) and the problem is shown.
    private func withoutOversized(_ changes: [OutgoingChange], account: String) async -> [OutgoingChange] {
        var sendable: [OutgoingChange] = []
        for change in changes {
            guard case .save(let snippet) = change.payload, !SnippetRecord.fits(snippet) else {
                sendable.append(change)
                continue
            }
            do { try await store.markFailed(retryIDs: change.retryIDs, account: account) } catch { problem = .localStorage }
            if problem != .localStorage { problem = .recordTooLarge }
            if syncingSession == nil { status = .failed(.recordTooLarge) }
        }
        return sendable
    }

    private func handle(_ event: SyncEngineEvent, from session: SyncSession) async -> FollowUp? {
        let account = session.account
        switch event {
        case .stateUpdated(let state):
            // Never persist a token that is past a change which was not stored.
            guard !replayNeeded else { break }
            do { try await store.saveSyncEngineState(state, account: account) } catch { problem = .localStorage }
        case .fetched(let changes, let unreadable):
            skippedRemoteRecords += unreadable
            var libraryChanged = false
            for change in changes where self.session === session {
                libraryChanged = await apply(change, account: account) || libraryChanged
            }
            if libraryChanged { await onLibraryChanged() }
        case .sent(let results):
            return await record(results, from: session)
        case .remoteDataReset:
            do {
                try await store.resetSyncMetadata(account: account)
                if try await store.prepareSync(account: account).reenabled { await onLibraryChanged() }
            } catch { problem = .localStorage }
            return .syncAgain
        case .accountChanged(let cloud):
            return .accountChanged(cloud)
        }
        return nil
    }

    /// Applies one remote change; true when the library changed. A record that fails validation or hits a
    /// damaged local row is skipped and counted, never retried blindly and never allowed to block the rest.
    private func apply(_ change: RemoteChange, account: String) async -> Bool {
        do {
            return try await store.applyRemote(change, account: account).libraryChanged
        } catch is KeyloomError {
            skippedRemoteRecords += 1
        } catch StoreError.corruptRecord {
            skippedRemoteRecords += 1
        } catch {
            problem = .localStorage
            replayNeeded = true
        }
        return false
    }

    /// The handed-out change an answer refers to. An answer for a snapshot this controller did not hand out (or
    /// no longer remembers) acknowledges nothing: the intents stay queued and are sent again, which is safe.
    private func answeredChange(for result: SendResult) -> OutgoingChange? {
        guard let candidates = sentBatch.removeValue(forKey: result.recordID) else { return nil }
        switch result.outcome {
        case .saved:
            return candidates.last { change in
                guard case .save(let sent) = change.payload else { return false }
                return result.sentRevision.map { sent.revision == $0 } ?? true
            }
        case .deleted:
            return candidates.last { $0.payload == .delete }
        case .serverHasNewer, .failed:
            return candidates.last
        }
    }

    private func record(_ results: [SendResult], from session: SyncSession) async -> FollowUp? {
        let account = session.account
        var libraryChanged = false
        var followUp: FollowUp?
        for result in results {
            if case .serverHasNewer = result.outcome { followUp = followUp ?? .syncAgain }
            guard let change = answeredChange(for: result) else { continue }
            do {
                switch result.outcome {
                case .saved(let fields): try await store.recordSent(change, systemFields: fields, account: account)
                case .deleted: try await store.recordSent(change, systemFields: nil, account: account)
                case .serverHasNewer(let remote):
                    libraryChanged = await apply(remote, account: account) || libraryChanged
                case .failed(let kind):
                    try await store.markFailed(retryIDs: change.retryIDs, account: account)
                    switch kind {
                    case .quotaExceeded: quotaHit = true
                    case .networkUnavailable: problem = .network
                    case .recordTooLarge: problem = .recordTooLarge
                    case .other(let code): problem = .unexpected(code: code)
                    case .notAuthenticated: followUp = .signedOut
                    }
                }
            } catch {
                problem = .localStorage
            }
        }
        if libraryChanged { await onLibraryChanged() }
        return followUp
    }
}
