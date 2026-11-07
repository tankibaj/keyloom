import Foundation
import Observation

enum PickerEmptyState: Equatable {
    case emptyLibrary
    case noResults(query: String)
}

/// One picker session: search, selection, preview and Copy (the picker only copies, it never inserts). Typing
/// runs the local search only: no model, no network.
@MainActor @Observable
final class PickerModel {
    var query = "" { didSet { if query != oldValue { search() } } }
    private(set) var rows: [SnippetRow] = []
    var selection: UUID? { didSet { if selection != oldValue { loadPreview() } } }
    private(set) var emptyState: PickerEmptyState?
    private(set) var preview: Preview?
    /// What to tell the user when the last Copy did nothing.
    private(set) var notice: String?
    @ObservationIgnored var onHide: (@MainActor () -> Void)?
    @ObservationIgnored var onReshow: (@MainActor () -> Void)?
    @ObservationIgnored var onReturnFocus: (@MainActor () -> Void)?

    @ObservationIgnored private let library: SnippetLibrary
    @ObservationIgnored private let inserter: SnippetInserter
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(library: SnippetLibrary, inserter: SnippetInserter) {
        self.library = library
        self.inserter = inserter
        search()
    }

    var canCopy: Bool { selection != nil }

    /// Waits for the search and preview work started so far.
    func idle() async {
        while !tasks.isEmpty { await tasks.removeFirst().value }
    }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : rows.count)
        selection = rows[min(max(current + delta, 0), rows.count - 1)].id
    }

    /// Hides the window first, then copies; comes back with a message when nothing was copied.
    func copySelected() async {
        guard let id = selection else { return }
        notice = nil
        onHide?()
        switch await inserter.copy(snippetID: id) {
        case .copied?, nil: onReturnFocus?()
        case let outcome?:
            notice = Self.message(for: outcome)
            onReshow?()
        }
    }

    func cancel() {
        onHide?()
        onReturnFocus?()
    }

    // MARK: Private

    private func search() {
        generation += 1
        let mine = generation
        track { await $0.applyResults(for: mine) }
    }

    private func applyResults(for ticket: Int) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = await library.search(query: text)
        // A newer keystroke owns the list.
        guard ticket == generation else { return }
        switch outcome {
        case .results(let hits):
            rows = hits.map { SnippetRow($0.snippet) }
            emptyState = nil
            if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
        case .emptyLibrary, .noMatches:
            rows = []
            emptyState = outcome == .emptyLibrary ? .emptyLibrary : .noResults(query: query)
            selection = nil
        }
    }

    private func loadPreview() {
        guard let id = selection else {
            preview = nil
            return
        }
        track { model in
            let loaded = await model.inserter.preview(snippetID: id)
            if model.selection == id { model.preview = loaded }
        }
    }

    private func track(_ work: @escaping @MainActor (PickerModel) async -> Void) {
        tasks.append(Task { [self] in await work(self) })
    }

    private static func message(for outcome: InsertionOutcome) -> String {
        switch outcome {
        case .failedClosed(.snippetUnavailable):
            "This snippet no longer exists."
        default:
            "Keyloom couldn’t copy this snippet."
        }
    }
}
