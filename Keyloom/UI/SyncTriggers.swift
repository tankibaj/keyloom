import AppKit

/// Feeds the sync controller the events it cannot see itself: local commits (so a post-launch edit is sent
/// without waiting for a relaunch or Sync Now), iCloud account changes, and the app becoming active (an offline
/// launch re-checks the account). Remote applies are skipped: they came from the cloud and must not start another
/// sync. Events are handled one at a time, in order. All of it is a no-op while the sync switch is off.
@MainActor
final class SyncTriggers {
    private let controller: SyncController
    private let library: SnippetLibrary
    private let accountChanges: AsyncStream<Void>
    private let center: NotificationCenter
    private var tasks: [Task<Void, Never>] = []
    private var activationObserver: (any NSObjectProtocol)?

    init(controller: SyncController, library: SnippetLibrary, accountChanges: AsyncStream<Void>, center: NotificationCenter = .default) {
        self.controller = controller
        self.library = library
        self.accountChanges = accountChanges
        self.center = center
    }

    func start() {
        guard tasks.isEmpty else { return }
        let controller = controller
        let changes = library.changes  // subscribed now, so nothing committed after start() is missed
        tasks.append(Task {
            for await change in changes {
                switch change {
                case .remoteChangesApplied, .usageRecorded: continue
                case .created, .updated, .deleted, .restored: await controller.localChangesCommitted()
                }
            }
        })
        let account = accountChanges
        tasks.append(Task { for await _ in account { await controller.accountMayHaveChanged() } })
        activationObserver = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { await controller.accountMayHaveChanged() }
        }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        if let activationObserver { center.removeObserver(activationObserver) }
        activationObserver = nil
    }
}
