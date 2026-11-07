import Foundation

/// What the Mac knows about iCloud, as the engine adapter reports it.
enum CloudAccountStatus: Sendable, Equatable {
    /// `account` is a stable, opaque identifier of the signed-in user, namespaced for the store (never shown or logged).
    case available(account: String)
    case noAccount
    /// iCloud is disabled for this Mac or user by a restriction (IT or parental controls).
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
    /// This build is not signed with the iCloud entitlement, so CloudKit must not be touched at all.
    case buildNotProvisioned
}

/// Why a push or fetch failed, without any record content.
enum SyncFailureKind: Sendable, Equatable {
    case quotaExceeded
    case networkUnavailable
    case notAuthenticated
    case recordTooLarge
    /// A server or framework error this build does not classify: its code only.
    case other(code: Int)
}

struct SyncFailure: Error, Equatable, Sendable {
    let kind: SyncFailureKind
}

/// What the cloud answered for one pushed record.
enum SendOutcome: Sendable, Equatable {
    case saved(systemFields: Data?)
    case deleted
    /// The cloud holds a different version than the one the push was based on (or deleted it): this is that
    /// state, to be reconciled like any other remote change. The push is not retried blindly.
    case serverHasNewer(RemoteChange)
    case failed(SyncFailureKind)
}

struct SendResult: Sendable, Equatable {
    let recordID: UUID
    let outcome: SendOutcome
    /// For a save: the revision of the snapshot that was actually sent. An engine may build records in more than
    /// one batch, so the controller acknowledges only the queued intents that snapshot covers. Nil: the latest.
    let sentRevision: Int?

    init(recordID: UUID, outcome: SendOutcome, sentRevision: Int? = nil) {
        self.recordID = recordID
        self.outcome = outcome
        self.sentRevision = sentRevision
    }
}

/// Everything an engine reports to its session.
enum SyncEngineEvent: Sendable, Equatable {
    /// The engine's serialized state changed: persist it for this account.
    case stateUpdated(Data)
    /// Changes from the cloud, and how many records could not be decoded by this build.
    case fetched([RemoteChange], unreadable: Int)
    case sent([SendResult])
    /// The account's cloud data was erased from outside (for example by the user in iCloud settings).
    case remoteDataReset
    case accountChanged(CloudAccountStatus)
}

/// The process boundary to CloudKit: a thin adapter over `CKSyncEngine` in the app, a fake in tests. The
/// controller starts it with a session for one account and ignores everything a session says once it was
/// stopped, so an adapter may deliver late.
protocol SyncEngineAdapter: Sendable {
    func accountStatus() async -> CloudAccountStatus
    /// Starts delivering events to `session` for the session's account, resuming from `state`.
    func start(session: SyncSession, state: Data?) async throws
    /// Stops the engine without deleting any record, locally or in the cloud.
    func stop() async
    /// Fetches remote changes, then sends queued local ones, reporting through the session. Throws `SyncFailure`.
    func syncNow() async throws
}

enum SyncUnavailableReason: Sendable, Equatable {
    /// iCloud is restricted on this Mac: sync is unavailable, the local library is not.
    case restricted
    case temporarilyUnavailable
    /// A development or unsigned build: iCloud was never set up for it.
    case buildNotProvisioned
}

/// A sync problem that stops sync, never local use. Carries no snippet text.
enum SyncProblem: Sendable, Equatable {
    case network
    case recordTooLarge
    case localStorage
    case unexpected(code: Int)
}

enum SyncStatus: Sendable, Equatable {
    case off
    case checkingAccount
    case signedOut
    case unavailable(SyncUnavailableReason)
    case syncing
    case upToDate(lastSyncedAt: Date)
    case quotaExceeded
    case failed(SyncProblem)
}
