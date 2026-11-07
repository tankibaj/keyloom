import Foundation
import Observation

/// Sidebar rows; each maps to a `LibraryFilter`.
enum SidebarItem: Hashable, Sendable {
    case all, recentlyUsed, pinned, tag(String)

    var filter: LibraryFilter {
        switch self {
        case .all: .all
        case .recentlyUsed: .recentlyUsed
        case .pinned: .pinned
        case .tag(let tag): .tag(tag)
        }
    }
}

struct SidebarCounts: Equatable, Sendable {
    var all = 0
    var recentlyUsed = 0
    var pinned = 0
}

/// One list row. Deliberately small: the body stays in the library, so a long list stays cheap.
struct SnippetRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let icon: SnippetIcon
    let keyword: String?
    let enabled: Bool
    let pinned: Bool

    init(_ snippet: Snippet) {
        id = snippet.id
        name = snippet.name
        icon = snippet.icon
        keyword = snippet.keyword.flatMap { $0.isEmpty ? nil : $0 }
        enabled = snippet.enabled
        pinned = snippet.pinned
    }

    /// What VoiceOver reads for the row.
    var accessibilityLabel: String {
        var parts = [name]
        if let keyword { parts.append("keyword \(keyword)") }
        if keyword != nil, !enabled { parts.append("expansion off") }
        if pinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }
}

/// Why the list is empty. Each case has a keyboard-reachable way out in the view.
enum LibraryEmptyState: Equatable, Sendable {
    case emptyLibrary
    case noResults(query: String)
    case emptyFilter(SidebarItem)
}

/// The library window's list state. Views stay thin over this; every mutation goes through `SnippetLibrary`.
@MainActor @Observable
final class LibraryViewModel {
    let library: SnippetLibrary
    var sidebarItem: SidebarItem = .all { didSet { if sidebarItem != oldValue { launch { await $0.refresh() } } } }
    var query = "" { didSet { if query != oldValue { launch { await $0.refresh() } } } }
    var selection: UUID?
    var undoManager: UndoManager?
    private(set) var rows: [SnippetRow] = []
    private(set) var tags: [TagSummary] = []
    private(set) var counts = SidebarCounts()
    private(set) var emptyState: LibraryEmptyState?
    /// Set when an action fails; the view shows it in an alert. Never contains snippet text.
    var errorMessage: String?

    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastDeleted: UUID?

    init(library: SnippetLibrary) {
        self.library = library
    }

    // MARK: Reading

    func refresh() async {
        let all = await library.allSnippets()
        let tags = await library.tags()
        let outcome = await library.search(query: query.trimmingCharacters(in: .whitespacesAndNewlines), filter: sidebarItem.filter)
        // A newer query or filter arrived while the library answered.
        guard !Task.isCancelled else { return }
        self.tags = tags
        counts = SidebarCounts(all: all.count, recentlyUsed: all.filter { $0.lastUsedAt != nil }.count, pinned: all.filter(\.pinned).count)
        switch outcome {
        case .results(let hits):
            rows = hits.map { SnippetRow($0.snippet) }
            emptyState = nil
        case .emptyLibrary:
            rows = []
            emptyState = .emptyLibrary
        case .noMatches:
            rows = []
            emptyState = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyFilter(sidebarItem) : .noResults(query: query)
        }
    }

    /// Follows commits made elsewhere (the editor, later sync and the picker). Ends when the library closes.
    func observeChanges() async {
        for await _ in library.changes { await refresh() }
    }

    func clearSearch() async {
        query = ""
        await idle()
    }

    func showAll() async {
        query = ""
        sidebarItem = .all
        await idle()
    }

    // MARK: Actions

    func duplicate(id: UUID) async {
        guard let copy = await attempt({ try await library.duplicate(id: id) }) else { return }
        await refresh()
        selection = copy.id
    }

    func togglePin(id: UUID) async {
        guard let pinned = rows.first(where: { $0.id == id })?.pinned else { return }
        guard await attempt({ try await library.setPinned(!pinned, id: id) }) != nil else { return }
        await refresh()
    }

    /// Soft delete with Cmd-Z: the next row (else the previous) takes the selection so focus never drops out of the list.
    func delete(id: UUID) async {
        let neighbor = rows.firstIndex { $0.id == id }.flatMap { index in
            rows.indices.contains(index + 1) ? rows[index + 1].id : (index > 0 ? rows[index - 1].id : nil)
        }
        guard await attempt({ try await library.delete(id: id) }) != nil else { return }
        lastDeleted = id
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.launch { await $0.undoLastDelete() } }
        }
        undoManager?.setActionName("Delete Snippet")
        if selection == id { selection = neighbor }
        await refresh()
    }

    func undoLastDelete() async {
        guard let id = lastDeleted else { return }
        lastDeleted = nil
        guard await attempt({ try await library.restore(id: id) }) != nil else { return }
        await refresh()
        selection = id
    }

    /// Runs `operation` after the previous queued one; `idle()` waits for the queue. The undo manager and
    /// property observers cannot await, so they queue here.
    func launch(_ operation: @escaping @MainActor (LibraryViewModel) async -> Void) {
        let previous = pending
        pending = Task { [self] in
            await previous?.value
            await operation(self)
        }
    }

    func idle() async { await pending?.value }

    /// Runs one library write; a failure becomes `errorMessage` and returns nil.
    func attempt<T>(_ write: () async throws -> T) async -> T? {
        do {
            return try await write()
        } catch {
            errorMessage = UserMessage.describe(error)
            return nil
        }
    }
}

enum UserMessage {
    /// Library and core errors carry IDs and counts only, so their descriptions are safe to show.
    static func describe(_ error: Error) -> String {
        switch error {
        case let error as LocalizedError where error.errorDescription != nil: error.errorDescription!
        case KeyloomError.invalidSnippet(let field, let reason): "The snippet’s \(field) \(reason)."
        case KeyloomError.multipleCursors: "A snippet can have only one cursor placeholder."
        case is KeyloomError: "The snippet text could not be saved."
        default: "Something went wrong."
        }
    }
}
