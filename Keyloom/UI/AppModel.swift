import Foundation
import Observation

/// Every way to leave an editor that may hold unsaved edits.
enum DismissalRequest: Equatable {
    case select(UUID?)
    case newSnippet
    case cancelEdit
    case closeWindow
    case quit
}

enum DismissalChoice {
    case save, discard, keepEditing
}

/// Root state of the library window and the single owner of the editor session and its dirty-edit guard.
/// Later surfaces (menu-bar popover, picker, Settings) read the same model: `library` for data, `libraryModel` for
/// list state, `requestNewSnippet()` and `requestSelection(_:)` to navigate.
@MainActor @Observable
final class AppModel {
    enum Phase {
        case opening
        case ready(SnippetLibrary, LibraryViewModel)
        case failed(String)
    }

    let dataDirectory: URL
    private(set) var phase = Phase.opening
    private(set) var editor: EditorViewModel?
    /// Set while the Save / Discard / Keep Editing sheet is up.
    private(set) var pendingDismissal: DismissalRequest?
    /// Bumped by Find; the toolbar search field takes focus when it changes.
    private(set) var searchFocusRequests = 0
    /// Set by the window and app delegates: what "proceed" means once edits are saved or discarded.
    @ObservationIgnored var closeWindowAction: (@MainActor () -> Void)?
    @ObservationIgnored var quitAction: (@MainActor () -> Void)?
    /// Daily, pre-import and pre-restore snapshots, and the folder where the store puts its pre-migration copies.
    let snapshots: SnapshotManager
    /// Why the last daily snapshot failed, for Settings. The library works regardless.
    private(set) var snapshotError: String?
    @ObservationIgnored private let openLibrary: @MainActor (URL) async throws -> SnippetLibrary
    /// Called after each library change was applied to the open editor (tests wait on it).
    @ObservationIgnored var onChangeHandled: (@MainActor () -> Void)?
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var changeObserver: Task<Void, Never>?
    @ObservationIgnored private var writingToolsPolicy: WritingAssistancePolicy?
    @ObservationIgnored private var dayChangeObservers: [any NSObjectProtocol] = []
    /// The newest snapshot started by a day change, for tests to await.
    @ObservationIgnored private(set) var pendingSnapshot: Task<Void, Never>?

    /// `openLibrary` replaces the real database opener (tests).
    init(dataDirectory: URL = DataLocation.resolve(), snapshots: SnapshotManager? = nil,
         openLibrary: (@MainActor (URL) async throws -> SnippetLibrary)? = nil) {
        self.dataDirectory = dataDirectory
        let manager = snapshots ?? SnapshotManager(directory: DataLocation.snapshotDirectory(in: dataDirectory), now: { Date() })
        self.snapshots = manager
        // The store's automatic pre-migration copies go beside the snapshots.
        self.openLibrary = openLibrary ?? { try await DataLocation.openLibrary(in: $0, backupDirectory: manager.migrationBackupDirectory) }
    }

    var library: SnippetLibrary? {
        if case .ready(let library, _) = phase { library } else { nil }
    }

    var libraryModel: LibraryViewModel? {
        if case .ready(_, let model) = phase { model } else { nil }
    }

    /// Opens the library and loads the list. Runs again after a failure (Try Again). Callers that overlap (the
    /// environment at launch and the library window) share one open.
    func open() async {
        if library != nil { return }
        if let opening {
            await opening.value
            return
        }
        let task = Task { await performOpen() }
        opening = task
        await task.value
        opening = nil
    }

    private func performOpen() async {
        phase = .opening
        do {
            let library = try await openLibrary(dataDirectory)
            let model = LibraryViewModel(library: library)
            model.selectionRequest = { [weak self] id in await self?.requestSelection(id) }
            await model.refresh()
            phase = .ready(library, model)
            observeLibraryChanges(of: library)
            await takeDailySnapshot(of: library)
        } catch {
            phase = .failed(UserMessage.describe(error))
        }
    }

    /// One app-lifetime subscriber (the window's own list refresh stops with the window): keeps an open, clean
    /// editor current when sync, an import or another surface changes the snippet it shows.
    private func observeLibraryChanges(of library: SnippetLibrary) {
        let changes = library.changes
        changeObserver?.cancel()
        changeObserver = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                if case .usageRecorded = change { continue }
                await editor?.refreshFromLibrary()
                onChangeHandled?()
            }
        }
    }

    /// At most one per day and only when the library changed (`SnapshotManager`). A failure is kept for Settings
    /// and never blocks the library.
    private func takeDailySnapshot(of library: SnippetLibrary) async {
        do {
            _ = try await library.takeDailySnapshot(using: snapshots)
            snapshotError = nil
        } catch {
            snapshotError = UserMessage.describe(error)
        }
    }

    /// The editor body is the one prose field. Writing Tools follow the assistance policy, now and on every
    /// change (a managed profile can switch them off while an editor is open).
    func bindWritingTools(to policy: WritingAssistancePolicy) {
        writingToolsPolicy = policy
        policy.observeChanges { [weak self] _ in self?.applyWritingTools() }
        applyWritingTools()
    }

    private func applyWritingTools() {
        guard let policy = writingToolsPolicy else { return }
        editor?.bodyController.writingToolsBehavior = policy.snapshot.writingToolsBehavior(forProseField: true)
    }

    /// Takes a daily snapshot again when the day rolls over or the clock or time zone jumps, so a Mac that stays
    /// up for days still backs up. At most one per day (`SnapshotManager`); a failure is shown in Settings only.
    func observeDayChanges(center: NotificationCenter = .default) {
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let library = self.library else { return }
                    self.pendingSnapshot = Task { await self.takeDailySnapshot(of: library) }
                }
            }
            dayChangeObservers.append(token)
        }
    }

    func requestSearchFocus() { searchFocusRequests += 1 }

    // MARK: Dismissal guard

    /// True when nothing unsaved is at risk, so the caller may go ahead. Otherwise the sheet is raised for `request`.
    func guardDismissal(_ request: DismissalRequest) -> Bool {
        guard editor?.isDirty == true else { return true }
        pendingDismissal = request
        return false
    }

    func requestSelection(_ id: UUID?) async {
        if case .existing(let current)? = editor?.target, current == id { libraryModel?.selection = id; return }
        // Deleting the edited snippet is not a dismissal worth asking about: there is nothing left to save into.
        var editedSnippetGone = false
        if case .existing(let current)? = editor?.target { editedSnippetGone = await library?.snippet(id: current) == nil }
        if editedSnippetGone || guardDismissal(.select(id)) { await perform(.select(id)) }
    }

    func requestNewSnippet() async {
        if guardDismissal(.newSnippet) { await perform(.newSnippet) }
    }

    func requestCancel() async {
        if guardDismissal(.cancelEdit) { await perform(.cancelEdit) }
    }

    /// For the window's close button: false means the sheet is up and the window stays.
    func shouldCloseWindow() -> Bool { guardDismissal(.closeWindow) }

    /// For `applicationShouldTerminate`.
    func shouldTerminate() -> Bool { guardDismissal(.quit) }

    func resolvePending(_ choice: DismissalChoice) async {
        guard let request = pendingDismissal else { return }
        pendingDismissal = nil
        switch choice {
        case .keepEditing: return
        case .discard: break
        case .save: guard await saveEditor() else { return }
        }
        await perform(request)
    }

    @discardableResult
    func saveEditor() async -> Bool {
        guard let editor, await editor.save() else { return false }
        if case .existing(let id) = editor.target { libraryModel?.selection = id }
        return true
    }

    private func perform(_ request: DismissalRequest) async {
        switch request {
        case .select(let id):
            libraryModel?.selection = id
            if let id, let library, let snippet = await library.snippet(id: id) {
                editor = EditorViewModel(library: library, snippet: snippet)
                applyWritingTools()
            } else {
                editor = nil
            }
        case .newSnippet:
            guard let library else { return }
            libraryModel?.selection = nil
            editor = EditorViewModel(library: library, snippet: nil)
            applyWritingTools()
        case .cancelEdit:
            if editor?.target == .new { editor = nil } else { editor?.revert() }
        case .closeWindow:
            editor?.revert()
            closeWindowAction?()
        case .quit:
            editor?.revert()
            quitAction?()
        }
    }
}
