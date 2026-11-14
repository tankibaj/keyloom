import Foundation
import Observation

/// Sidebar rows; each maps to a `LibraryFilter`, except the trash, which lists `deletedRows` instead.
enum SidebarItem: Hashable, Sendable {
    case all, recentlyUsed, pinned, tag(String), recentlyDeleted

    var filter: LibraryFilter {
        switch self {
        case .all, .recentlyDeleted: .all
        case .recentlyUsed: .recentlyUsed
        case .pinned: .pinned
        case .tag(let tag): .tag(tag)
        }
    }
}

/// How the list is ordered. Name is the library's own order (pinned first, then by name).
enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case name, recentlyEdited, recentlyUsed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .recentlyEdited: "Recently Edited"
        case .recentlyUsed: "Recently Used"
        }
    }

    /// Stable; pinned snippets stay first, ties keep the library's order. A search keeps its relevance order.
    func apply(to snippets: [Snippet]) -> [Snippet] {
        switch self {
        case .name: return snippets
        case .recentlyEdited: return Self.ordered(snippets) { $0.updatedAt }
        case .recentlyUsed: return Self.ordered(snippets) { $0.lastUsedAt ?? .distantPast }
        }
    }

    private static func ordered(_ snippets: [Snippet], by date: (Snippet) -> Date) -> [Snippet] {
        let indexed = snippets.enumerated().sorted { a, b in
            if a.element.pinned != b.element.pinned { return a.element.pinned }
            let (x, y) = (date(a.element), date(b.element))
            return x == y ? a.offset < b.offset : x > y
        }
        return indexed.map(\.element)
    }
}

/// What the sidebar footer says about typing expansion: Accessibility first, then pause. Words and counts only.
enum ExpansionStatus: Equatable, Sendable {
    case on, paused, needsAccessibility

    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    init(_ status: HostStatus) {
        if !status.permissions.accessibility { self = .needsAccessibility } else { self = status.isPaused ? .paused : .on }
    }

    var title: String {
        switch self {
        case .on: "Expansion on"
        case .paused: "Paused"
        case .needsAccessibility: "Needs Accessibility"
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
    /// One line of the body as typed (placeholders as their source), for the second line of the row.
    let preview: String

    /// Enough for any list column; the view truncates to one line.
    static let previewLimit = 120

    init(_ snippet: Snippet) {
        id = snippet.id
        name = snippet.name
        icon = snippet.icon
        keyword = snippet.keyword.flatMap { $0.isEmpty ? nil : $0 }
        enabled = snippet.enabled
        pinned = snippet.pinned
        preview = Self.preview(of: snippet.template)
    }

    /// The body flattened to one line: whitespace runs collapse to one space, list markers are left out, and the
    /// walk stops once the limit is reached so a huge body costs nothing.
    static func preview(of document: Document, limit: Int = previewLimit) -> String {
        var text = ""
        var pendingSpace = false
        func add(_ piece: String) {
            for character in piece {
                if character.isWhitespace || character.isNewline {
                    pendingSpace = !text.isEmpty
                } else {
                    if pendingSpace { text.append(" "); pendingSpace = false }
                    text.append(character)
                }
                if text.count >= limit { return }
            }
        }
        for paragraph in document.paragraphs {
            pendingSpace = !text.isEmpty
            for run in paragraph.runs {
                for span in run.spans {
                    switch span {
                    case .literal(let literal): add(literal)
                    case .token(let token): add(token.raw)
                    }
                    if text.count >= limit { return String(text.prefix(limit)) }
                }
            }
        }
        return text
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

struct DeletedRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let icon: SnippetIcon
    let enabled: Bool
    let deletedAt: Date
}

/// Why the list is empty. Each case has a keyboard-reachable way out in the view.
enum LibraryEmptyState: Equatable, Sendable {
    case emptyTrash
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
    var sort: LibrarySort = .name { didSet { if sort != oldValue { launch { await $0.refresh() } } } }
    /// How the model asks for a selection change it makes itself (duplicate, delete, undo). `AppModel` sets it to
    /// route through the dirty-edit guard; without it the selection just changes.
    @ObservationIgnored var selectionRequest: (@MainActor (UUID?) async -> Void)?
    var undoManager: UndoManager?
    private(set) var rows: [SnippetRow] = []
    private(set) var tags: [TagSummary] = []
    private(set) var counts = SidebarCounts()
    private(set) var deletedRows: [DeletedRow] = []
    private(set) var emptyState: LibraryEmptyState?
    /// Set when an action fails; the view shows it in an alert. Never contains snippet text.
    var errorMessage: String?
    /// A non-error outcome worth saying, such as a snippet restored with expansion off.
    var notice: String?

    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastDeleted: UUID?

    init(library: SnippetLibrary) {
        self.library = library
    }

    /// The window title: where you are.
    var title: String {
        switch sidebarItem {
        case .all: "All Snippets"
        case .recentlyUsed: "Recently Used"
        case .pinned: "Pinned"
        case .tag(let tag): tag
        case .recentlyDeleted: "Recently Deleted"
        }
    }

    /// The window subtitle; shown on every page so the toolbar height never changes.
    var subtitle: String {
        let count = sidebarItem == .recentlyDeleted ? deletedRows.count : rows.count
        return count == 1 ? "1 snippet" : "\(count) snippets"
    }

    // MARK: Reading

    func refresh() async {
        let all = await library.allSnippets()
        let tags = await library.tags()
        self.tags = tags
        counts = SidebarCounts(all: all.count, recentlyUsed: all.filter { $0.lastUsedAt != nil }.count, pinned: all.filter(\.pinned).count)
        if sidebarItem == .recentlyDeleted {
            await refreshDeleted()
            return
        }
        deletedRows = []
        let outcome = await library.search(query: query.trimmingCharacters(in: .whitespacesAndNewlines), filter: sidebarItem.filter)
        switch outcome {
        case .results(let hits):
            let ordered = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sort.apply(to: hits.map(\.snippet)) : hits.map(\.snippet)
            rows = ordered.map(SnippetRow.init)
            emptyState = nil
        case .emptyLibrary:
            rows = []
            emptyState = .emptyLibrary
        case .noMatches:
            rows = []
            emptyState = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyFilter(sidebarItem) : .noResults(query: query)
        }
    }

    private func refreshDeleted() async {
        rows = []
        guard let deleted = await attempt({ try await library.deletedSnippets() }) else { return }
        deletedRows = deleted.map { DeletedRow(id: $0.snippet.id, name: $0.snippet.name, icon: $0.snippet.icon, enabled: $0.snippet.enabled, deletedAt: $0.deletedAt) }
        emptyState = deletedRows.isEmpty ? .emptyTrash : nil
    }

    /// Follows commits made elsewhere (the editor, later sync and the picker). Ends when the library closes.
    func observeChanges() async {
        // Subscribe first, then read: a change committed in between is never missed.
        let changes = library.changes
        await refresh()
        for await _ in changes { await refresh() }
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
        await select(copy.id)
    }

    func select(_ id: UUID?) async {
        if let selectionRequest { await selectionRequest(id) } else { selection = id }
    }

    /// Renames a tag everywhere; the sidebar follows the renamed tag.
    func renameTag(_ old: String, to new: String) async {
        let target = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard await attempt({ try await library.renameTag(from: old, to: new) }) != nil else { return }
        if sidebarItem == .tag(old) { sidebarItem = .tag(target) }
        await refresh()
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
        await refresh()
        if selection == id { await select(neighbor) }
    }

    /// Recover from Recently Deleted. A keyword another snippet took meanwhile comes back with expansion off.
    func restoreDeleted(id: UUID) async {
        notice = nil
        let wasEnabled = deletedRows.first { $0.id == id }?.enabled
        guard let restored = await attempt({ try await library.restore(id: id) }) else { return }
        if wasEnabled == true, !restored.enabled, let keyword = restored.keyword {
            notice = "“\(restored.name)” is back with expansion off: another snippet now uses \(keyword)."
        }
        await refresh()
    }

    func undoLastDelete() async {
        guard let id = lastDeleted else { return }
        lastDeleted = nil
        guard await attempt({ try await library.restore(id: id) }) != nil else { return }
        await refresh()
        await select(id)
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
        case RenderError.choiceNotInOptions(let name): "The default or sample value for “\(name)” is not one of its choices."
        case RenderError.missingArguments: "Some arguments have no sample value."
        case is KeyloomError: "The snippet text could not be saved."
        default: "Something went wrong."
        }
    }
}
