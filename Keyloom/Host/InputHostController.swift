import AppKit
import Observation
import os

@MainActor
protocol EventTapControlling: AnyObject {
    var isRunning: Bool { get }
    /// False when macOS refuses the tap (Accessibility not granted).
    func start() -> Bool
    func stop()
}

extension EventTap: EventTapControlling {}

/// Implemented by the UI. Called from the menu command and the global shortcut, after the destination was
/// captured (before any Keyloom window exists) and with nothing in the destination touched.
@MainActor
protocol PickerPresenting: AnyObject {
    /// `destination` is nil when the focused field is unusable (secure, excluded, unreadable, no permission):
    /// the picker should then offer Copy only.
    func presentPicker(destination: CapturedDestination?)
}

/// Opaque handle to the field that was focused when the picker was requested. Pass it back to
/// `InputHostController.insert`; it is re-verified there, never trusted.
struct CapturedDestination: Equatable, Sendable {
    fileprivate let target: BoundTarget
}

/// What Settings and the menu show. Counts and states only: never typed text, snippet text or prompts.
struct HostStatus: Equatable, Sendable {
    var permissions: PermissionStatus
    var isTapRunning = false
    var isPaused = false
    var isSecureInputActive = false
    var shortcut: ShortcutState = .unregistered
    var lastOutcome: InsertionOutcome?
    /// A refused insertion can still be delivered by an explicit `copyOffered()`.
    var hasCopyOffer = false
    var counters = InputHost.Counters()
    var clipboardRestoresSkipped = 0
    var usageRecordFailures = 0
    var expandsInUninspectableApps = true
}

/// Every OS boundary the host touches, so the whole host runs against fakes in tests.
@MainActor
struct HostDependencies {
    var destination: DestinationAccess
    var pasteboard: PasteboardAccess
    var keys: PasteKeyPosting
    var permissions: PermissionChecking
    var environment: InputEnvironment
    var workspace: WorkspaceInfo
    var hotKeys: HotKeyRegistering
    var makeTap: (InputHost) -> EventTapControlling
    var settle: (TimeInterval) async -> Void
    var ownBundleID: String?
    /// Seconds between permission re-checks while a permission is missing and the controller is started; nil
    /// disables polling. A granted app is not polled: each check is a synchronous round trip to the TCC daemon.
    var permissionPollInterval: TimeInterval?
    /// Registers for permission changes the system announces and returns the remover.
    var observePermissionChanges: (@escaping @MainActor () -> Void) -> () -> Void = { _ in {} }
    /// Registers for app-activation changes and returns the remover.
    var observeAppActivation: (@escaping @MainActor () -> Void) -> () -> Void = { _ in {} }

    static func system() -> HostDependencies {
        HostDependencies(
            destination: AXDestination(), pasteboard: SystemPasteboard(), keys: SystemPasteKeys(), permissions: SystemPermissions(),
            environment: SystemInputEnvironment(), workspace: SystemWorkspace(), hotKeys: CarbonHotKeys(),
            makeTap: { EventTap(host: $0) },
            settle: { try? await Task.sleep(for: .seconds($0)) },
            ownBundleID: Bundle.main.bundleIdentifier,
            permissionPollInterval: 1,
            observePermissionChanges: { changed in
                // The system posts this when Accessibility trust changes, before the answer settles.
                let token = DistributedNotificationCenter.default().addObserver(
                    forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
                ) { _ in
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        changed()
                    }
                }
                return { DistributedNotificationCenter.default().removeObserver(token) }
            },
            observeAppActivation: { invalidate in
                let token = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
                ) { _ in MainActor.assumeIsolated { invalidate() } }
                return { NSWorkspace.shared.notificationCenter.removeObserver(token) }
            })
    }
}

/// The input host's single entry point for the UI: permission status, pause, excluded apps, the global
/// shortcut, the picker hooks and an observable `status`. Wires the event tap, the matcher, the destination
/// checks and the insertion engine; the UI only implements `ArgumentPrompting` and `PickerPresenting`.
@MainActor
@Observable
final class InputHostController {
    private static let log = Logger(subsystem: "com.thenaim.keyloom", category: "expansion")

    private(set) var status: HostStatus

    @ObservationIgnored let inputHost: InputHost
    /// The expansion in flight, nil when idle.
    @ObservationIgnored private(set) var expansionTask: Task<Void, Never>?

    @ObservationIgnored private let dependencies: HostDependencies
    @ObservationIgnored private let preferences: PreferencesStoring
    @ObservationIgnored private let picker: PickerPresenting
    @ObservationIgnored private let tap: EventTapControlling
    @ObservationIgnored private let binder: TargetBinder
    @ObservationIgnored private let engine: InsertionEngine
    @ObservationIgnored private let coordinator: ExpansionCoordinator
    @ObservationIgnored private let keystrokes: KeystrokeInserter
    @ObservationIgnored private var shortcuts: ShortcutManager!
    @ObservationIgnored private var userExcluded: Set<String>
    @ObservationIgnored private var copyOffer: RenderedSnippet?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var removeActivationObserver: (() -> Void)?
    @ObservationIgnored private var removePermissionObserver: (() -> Void)?
    @ObservationIgnored private var isStarted = false
    /// Typed expansions and picker insertions in flight; keys are dropped while any is.
    @ObservationIgnored private var suspensions = 0

    init(library: SnippetLibrary, prompter: ArgumentPrompting, picker: PickerPresenting, preferences: PreferencesStoring,
         dependencies: HostDependencies = .system()) {
        self.dependencies = dependencies
        self.preferences = preferences
        self.picker = picker
        let saved = preferences.load()
        userExcluded = saved.excludedBundleIDs
        status = HostStatus(permissions: dependencies.permissions.current(), expandsInUninspectableApps: saved.expandsInUninspectableApps)
        inputHost = InputHost(matcher: library.keywordMatcher, environment: dependencies.environment, workspace: dependencies.workspace)
        tap = dependencies.makeTap(inputHost)
        let settle = dependencies.settle
        let ownBundleID = dependencies.ownBundleID
        let exclusions: () -> Set<String> = { [inputHost] in MainActor.assumeIsolated { inputHost.excludedBundleIDs } }
        binder = TargetBinder(destination: dependencies.destination, environment: dependencies.environment,
                              permissions: dependencies.permissions, excludedBundleIDs: exclusions, settle: settle)
        engine = InsertionEngine(binder: binder, destination: dependencies.destination, permissions: dependencies.permissions,
                                 pasteboard: dependencies.pasteboard, keys: dependencies.keys, settle: settle)
        let pasteboard = dependencies.pasteboard
        keystrokes = KeystrokeInserter(
            destination: dependencies.destination, environment: dependencies.environment, workspace: dependencies.workspace,
            permissions: dependencies.permissions, pasteboard: pasteboard, keys: dependencies.keys,
            excludedBundleIDs: exclusions, settle: settle)
        coordinator = ExpansionCoordinator(library: library, binder: binder, engine: engine, prompter: prompter,
                                           keystrokes: keystrokes) {
            Self.renderEnvironment(pasteboard: pasteboard)
        }
        coordinator.onUsageRecordFailed = { [weak self] in self?.status.usageRecordFailures += 1 }
        inputHost.excludedBundleIDs = userExcluded.union(ownBundleID.map { [$0] } ?? [])
        inputHost.onMatch = { [weak self] match in self?.begin(match) }
        let countSkippedRestore: (ClipboardOutcome) -> Void = { [weak self] outcome in
            guard let self, outcome != .restored else { return }
            status.clipboardRestoresSkipped += 1
        }
        keystrokes.isEnabled = saved.expandsInUninspectableApps
        engine.onClipboardOutcome = countSkippedRestore
        keystrokes.onClipboardOutcome = countSkippedRestore
        shortcuts = ShortcutManager(registrar: dependencies.hotKeys) { [weak self] in self?.openPicker() }
    }

    // MARK: Lifecycle

    /// Registers the shortcut and starts the tap when permissions allow. Safe to call again.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        status.shortcut = shortcuts.apply(preferences.load().shortcut)
        removeActivationObserver = dependencies.observeAppActivation { [weak self] in self?.inputHost.invalidate() }
        removePermissionObserver = dependencies.observePermissionChanges { [weak self] in self?.refreshPermissions() }
        refreshPermissions()
    }

    func stop() {
        isStarted = false
        pollTimer?.invalidate()
        pollTimer = nil
        removeActivationObserver?()
        removeActivationObserver = nil
        removePermissionObserver?()
        removePermissionObserver = nil
        cancelExpansion()
        tap.stop()
        inputHost.isEnabled = false
        shortcuts.remove()
        status.shortcut = .unregistered
        publishState()
    }

    /// Prompts for the missing permissions. Call from a button, never at launch.
    func requestPermissions() { dependencies.permissions.request() }

    /// Re-reads the permissions (also on a timer while started). Loss stops the tap, drops pending work and
    /// leaves the destination untouched; a grant starts the tap.
    func refreshPermissions() {
        let current = dependencies.permissions.current()
        if current.inputReady {
            if !tap.isRunning { _ = tap.start() }
            inputHost.isEnabled = tap.isRunning
        } else {
            if tap.isRunning { tap.stop() }
            inputHost.isEnabled = false
            cancelExpansion()
        }
        if status.permissions != current { status.permissions = current }
        publishState()
        pollWhileMissing(ready: current.inputReady)
    }

    private func pollWhileMissing(ready: Bool) {
        guard isStarted, let interval = dependencies.permissionPollInterval else { return }
        if ready {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissions() }
            }
        }
    }

    // MARK: Settings

    func setPaused(_ paused: Bool) {
        inputHost.isPaused = paused
        if paused {
            cancelExpansion()
            inputHost.invalidate()
        }
        publishState()
    }

    /// Keyloom's own windows are always excluded in addition to these.
    func setExcludedBundleIDs(_ ids: Set<String>) {
        userExcluded = ids
        cancelExpansion()
        inputHost.excludedBundleIDs = ids.union(dependencies.ownBundleID.map { [$0] } ?? [])
        var saved = preferences.load()
        saved.excludedBundleIDs = ids
        preferences.save(saved)
    }

    var excludedBundleIDs: Set<String> { userExcluded }

    /// Whether keywords are typed over in apps Accessibility cannot inspect.
    func setExpandsInUninspectableApps(_ enabled: Bool) {
        keystrokes.isEnabled = enabled
        status.expandsInUninspectableApps = enabled
        cancelExpansion()
        var saved = preferences.load()
        saved.expandsInUninspectableApps = enabled
        preferences.save(saved)
    }

    /// The result says whether it registered, conflicts with another app, or failed; the shortcut is saved either way.
    @discardableResult
    func setShortcut(_ config: ShortcutConfig) -> ShortcutState {
        var saved = preferences.load()
        saved.shortcut = config
        preferences.save(saved)
        let state = shortcuts.apply(config)
        status.shortcut = state
        return state
    }

    // MARK: Picker

    /// Menu command and shortcut handler. Captures the focused field first, then hands over to the UI.
    func openPicker() {
        let captured: CapturedDestination?
        if case .success(let target) = binder.bindCaret() {
            captured = CapturedDestination(target: target)
        } else {
            captured = nil
        }
        picker.presentPicker(destination: captured)
    }

    /// Inserts a rendered snippet the user picked into the destination captured before the picker opened.
    /// Reactivates the original app, re-verifies field, caret and contents, and aborts leaving text intact.
    @discardableResult
    func insert(_ rendered: RenderedSnippet, into destination: CapturedDestination, route: InsertionRoute,
                snippetID: UUID?) async -> InsertionOutcome {
        suspend()
        defer { resume() }
        let outcome = await engine.insert(rendered, into: destination.target, route: route, reactivating: true)
        publish(await coordinator.finish(outcome, rendered: rendered, snippetID: snippetID))
        return outcome
    }

    /// Explicit user Copy of a rendered snippet (plain and styled). Never restored afterwards.
    func copy(_ rendered: RenderedSnippet) {
        status.lastOutcome = engine.copy(rendered)
    }

    /// Delivers the snippet of the last refused insertion to the clipboard. User-initiated only.
    func copyOffered() {
        guard let offer = copyOffer else { return }
        copy(offer)
        dismissCopyOffer()
    }

    func dismissCopyOffer() {
        copyOffer = nil
        status.hasCopyOffer = false
    }

    // MARK: Typed expansion

    private func suspend() {
        suspensions += 1
        inputHost.isSuspended = true
    }

    private func resume() {
        suspensions -= 1
        inputHost.isSuspended = suspensions > 0
        inputHost.invalidate()
    }

    /// Keys, clicks and app switches seen since start. While an expansion runs, every one of them is a reason for
    /// the keystroke route not to touch the field.
    private var activity: Int {
        let counters = inputHost.counters
        return counters.suppressedInactive + counters.syntheticIgnored + counters.invalidations
    }

    private func begin(_ match: KeywordMatch) {
        suspend()
        let baseline = activity
        expansionTask = Task { [weak self] in
            guard let self else { return }
            await process(match, baseline: baseline)
        }
    }

    private func process(_ match: KeywordMatch, baseline: Int) async {
        defer {
            resume()
            expansionTask = nil
        }
        publish(await coordinator.handle(match, interrupted: { [unowned self] in activity != baseline }))
    }

    /// Resolves once usage writes started by finished insertions have completed (they run after the host resumes).
    func waitForUsageRecording() async { await coordinator.waitForUsageRecording() }

    private func cancelExpansion() { expansionTask?.cancel() }

    private func publish(_ result: ExpansionResult) {
        // Outcome names only (enum cases), never text: how a refusal in another app can be told apart afterwards.
        Self.log.info("expansion outcome: \(String(describing: result.outcome), privacy: .public)")
        status.lastOutcome = result.outcome
        copyOffer = result.copyOffer
        status.hasCopyOffer = result.copyOffer != nil
        publishState()
    }

    /// Writes only a real change: an @Observable write wakes every observer, equal value or not.
    private func publishState() {
        var next = status
        next.isTapRunning = tap.isRunning
        next.isPaused = inputHost.isPaused
        next.isSecureInputActive = dependencies.environment.isSecureInputActive
        next.counters = inputHost.counters
        if next != status { status = next }
    }

    /// Clipboard text is read lazily, only when a template uses `{clipboard}`. The render runs off the main
    /// thread, so the read hops to it.
    private static func renderEnvironment(pasteboard: PasteboardAccess) -> RenderEnvironment {
        RenderEnvironment(date: Date(), timeZone: .current, locale: .current, makeUUID: { UUID() }) {
            if Thread.isMainThread { return MainActor.assumeIsolated { pasteboard.plainText() } }
            return DispatchQueue.main.sync { MainActor.assumeIsolated { pasteboard.plainText() } }
        }
    }
}
