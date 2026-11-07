import Foundation
import Observation

/// Which OS boundaries the app runs on: the real ones, or inert ones for UI tests and for the app hosting XCTest
/// (a unit-test run must never install an event tap or a global hotkey).
enum LaunchMode: Equatable {
    case live, uiTest

    static let uiTestArgument = "--keyloom-ui-test"

    static func resolve(arguments: [String] = CommandLine.arguments,
                        isRunningTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil) -> LaunchMode {
        arguments.contains(uiTestArgument) || isRunningTests ? .uiTest : .live
    }
}

/// The composition root: owns the library model and, once the library is open, the input host with the picker,
/// the argument prompt and the menu-bar model. The App struct only binds scenes to what is built here.
@MainActor @Observable
final class AppEnvironment {
    struct Services {
        let host: InputHostController
        let picker: PickerCoordinator
        let menuBar: MenuBarModel
        let settings: SettingsModels
        let sync: SyncController
    }

    let model: AppModel
    let mode: LaunchMode
    private(set) var services: Services?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let syncAdapter: (any SyncEngineAdapter)?
    @ObservationIgnored private var syncTriggers: SyncTriggers?
    @ObservationIgnored private var syncLaunch: Task<Void, Never>?
    @ObservationIgnored private let promptPresenter = PromptPanelPresenter()
    @ObservationIgnored private let pickerPanel = PickerPanelPresenter()

    init(model: AppModel = AppModel(), mode: LaunchMode = .resolve(), defaults: UserDefaults? = nil,
         syncAdapter: (any SyncEngineAdapter)? = nil) {
        self.model = model
        self.mode = mode
        self.defaults = defaults ?? Self.defaults(for: mode)
        self.syncAdapter = syncAdapter
    }

    /// UI-test runs start from empty preferences in their own domain and never touch the real ones.
    private static func defaults(for mode: LaunchMode) -> UserDefaults {
        guard mode == .uiTest, let suite = UserDefaults(suiteName: "app.keyloom.ui-test") else { return .standard }
        suite.removePersistentDomain(forName: "app.keyloom.ui-test")
        return suite
    }

    /// Opens the library, then starts the host. Safe to call again.
    func start() async {
        await model.open()
        guard services == nil, let library = model.library else { return }
        let prompter = ArgumentPromptCoordinator(presenter: promptPresenter) { await library.snippet(id: $0)?.name }
        let picker = PickerCoordinator(library: library, panel: pickerPanel, focus: WorkspaceFocusRestorer(), prompter: prompter)
        let host = InputHostController(library: library, prompter: prompter, picker: picker,
                                       preferences: UserDefaultsPreferences(defaults: defaults),
                                       dependencies: mode == .live ? .system() : .uiTest())
        picker.attach(host)
        host.start()
        // `library.syncStore` is the one store; sync changes reach the UI through `reloadAfterSync`.
        let syncPreference = SyncPreference(defaults: defaults)
        let adapter: any SyncEngineAdapter = syncAdapter ?? (mode == .live ? CKSyncEngineAdapter() : InertSyncAdapter())
        let sync = SyncController(store: library.syncStore, adapter: adapter, preference: syncPreference,
                                  onLibraryChanged: { await library.reloadAfterSync() })
        let assistancePolicy = mode == .live
            ? WritingAssistancePolicy(defaults: defaults)
            : WritingAssistancePolicy(defaults: defaults, availability: InertModelAvailability())
        let assistance = AssistanceService.make(policy: assistancePolicy,
                                                sessions: mode == .live ? SystemModelSessionFactory() : EchoModelSessionFactory())
        let settings = SettingsModels(
            appearance: AppearanceSettings(defaults: defaults), shortcut: ShortcutSettingsModel(host: host),
            expansion: ExpansionSettingsModel(host: host),
            backups: SyncBackupsModel(library: library, snapshots: model.snapshots),
            sync: SyncSettingsViewModel(controller: sync, preference: syncPreference),
            assistance: WritingAssistanceSettingsModel(policy: assistancePolicy))
        settings.appearance.applyCurrent()
        model.bindWritingTools(to: assistancePolicy, assistance: assistance)
        model.observeDayChanges()
        services = Services(host: host, picker: picker, menuBar: MenuBarModel(library: library, host: host, picker: picker),
                            settings: settings, sync: sync)
        // Only now: the account check and first sync go to the network, and the menu bar and Settings must
        // already be usable while iCloud answers (or does not).
        let triggers = SyncTriggers(controller: sync, library: library,
                                    accountChanges: mode == .live ? CKSyncEngineAdapter.accountChanges() : AsyncStream { $0.finish() })
        triggers.start()
        syncTriggers = triggers
        syncLaunch = Task { await sync.launch() }
    }

    /// For quitting: stops the sync engine (the saved switch is kept) and the triggers feeding it.
    func shutdown() async {
        syncTriggers?.stop()
        await services?.sync.shutdown()
    }
}
