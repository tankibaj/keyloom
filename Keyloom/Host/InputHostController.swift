import AppKit
import Observation

@MainActor
protocol EventTapControlling: AnyObject {
    var isRunning: Bool { get }
    /// False when macOS refuses the tap (Input Monitoring not granted).
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
    /// Seconds between permission re-checks while started; nil disables polling.
    var permissionPollInterval: TimeInterval?
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
    @ObservationIgnored private var shortcuts: ShortcutManager!
    @ObservationIgnored private var userExcluded: Set<String>
    @ObservationIgnored private var copyOffer: RenderedSnippet?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var removeActivationObserver: (() -> Void)?
    @ObservationIgnored private var isStarted = false

    init(library: SnippetLibrary, prompter: ArgumentPrompting, picker: PickerPresenting, preferences: PreferencesStoring,
         dependencies: HostDependencies = .system()) {
        self.dependencies = dependencies
        self.preferences = preferences
        self.picker = picker
        let saved = preferences.load()
        userExcluded = saved.excludedBundleIDs
        status = HostStatus(permissions: dependencies.permissions.current())
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
        coordinator = ExpansionCoordinator(library: library, binder: binder, engine: engine, prompter: prompter) {
            Self.renderEnvironment(pasteboard: pasteboard)
        }
        inputHost.excludedBundleIDs = userExcluded.union(ownBundleID.map { [$0] } ?? [])
        inputHost.onMatch = { [weak self] match in self?.begin(match) }
        engine.onClipboardOutcome = { [weak self] outcome in
            guard let self, outcome != .restored else { return }
            status.clipboardRestoresSkipped += 1
        }
        shortcuts = ShortcutManager(registrar: dependencies.hotKeys) { [weak self] in self?.openPicker() }
    }

    // MARK: Lifecycle

    /// Registers the shortcut and starts the tap when permissions allow. Safe to call again.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        status.shortcut = shortcuts.apply(preferences.load().shortcut)
        removeActivationObserver = dependencies.observeAppActivation { [weak self] in self?.inputHost.invalidate() }
        if let interval = dependencies.permissionPollInterval {
            pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissions() }
            }
        }
        refreshPermissions()
    }

    func stop() {
        isStarted = false
        pollTimer?.invalidate()
        pollTimer = nil
        removeActivationObserver?()
        removeActivationObserver = nil
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
        status.permissions = current
        publishState()
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
        inputHost.excludedBundleIDs = ids.union(dependencies.ownBundleID.map { [$0] } ?? [])
        var saved = preferences.load()
        saved.excludedBundleIDs = ids
        preferences.save(saved)
    }

    var excludedBundleIDs: Set<String> { userExcluded }

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
        inputHost.isSuspended = true
        defer {
            inputHost.isSuspended = false
            inputHost.invalidate()
        }
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

    private func begin(_ match: KeywordMatch) {
        inputHost.isSuspended = true
        expansionTask = Task { [weak self] in
            guard let self else { return }
            await process(match)
        }
    }

    private func process(_ match: KeywordMatch) async {
        defer {
            inputHost.isSuspended = false
            inputHost.invalidate()
            expansionTask = nil
        }
        publish(await coordinator.handle(match))
    }

    private func cancelExpansion() { expansionTask?.cancel() }

    private func publish(_ result: ExpansionResult) {
        status.lastOutcome = result.outcome
        copyOffer = result.copyOffer
        status.hasCopyOffer = result.copyOffer != nil
        if result.usageRecordFailed { status.usageRecordFailures += 1 }
        publishState()
    }

    private func publishState() {
        status.isTapRunning = tap.isRunning
        status.isPaused = inputHost.isPaused
        status.isSecureInputActive = dependencies.environment.isSecureInputActive
        status.counters = inputHost.counters
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
