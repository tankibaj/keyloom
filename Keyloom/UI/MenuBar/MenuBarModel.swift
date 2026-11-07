import Foundation
import Observation

/// The menu-bar popover: pinned and recently used snippets (searchable), pause, the picker and the host's last
/// refusal. Reads the host's observable status, so the pause switch and the shortcut warning are never stale.
/// Picking a snippet inserts it into the field focused when it was clicked, or copies it when no field can be used.
@MainActor @Observable
final class MenuBarModel {
    /// The popover lists the first few; the library window has the rest.
    static let rowLimit = 5

    var query = ""
    private(set) var pinned: [SnippetRow] = []
    private(set) var recents: [SnippetRow] = []
    private(set) var notice: String?

    @ObservationIgnored private let library: SnippetLibrary
    @ObservationIgnored private let host: InputHostController
    @ObservationIgnored private let picker: PickerCoordinator

    init(library: SnippetLibrary, host: InputHostController, picker: PickerCoordinator) {
        self.library = library
        self.host = host
        self.picker = picker
    }

    var isPaused: Bool {
        get { host.status.isPaused }
        set { host.setPaused(newValue) }
    }

    var symbolName: String { isPaused ? "pause.circle" : "text.cursor" }
    var shortcutWarning: String? { ShortcutDisplay.message(for: host.status.shortcut) }
    var hasCopyOffer: Bool { host.status.hasCopyOffer }

    func refresh() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        pinned = await rows(for: .pinned, matching: text)
        recents = await rows(for: .recentlyUsed, matching: text)
    }

    func insert(_ id: UUID) async {
        notice = nil
        guard let inserter = picker.inserter else {
            notice = "Keyloom is still starting."
            return
        }
        if let destination = picker.captureDestination() {
            switch await inserter.insert(snippetID: id, into: destination) {
            case nil: picker.restoreFocus()
            case .replaced?: break
            case _?: notice = "Keyloom couldn’t confirm the field you were in, so it left your text unchanged."
            }
        } else if await inserter.copy(snippetID: id) == .copied {
            notice = "No text field is ready for insertion, so the snippet was copied. Paste it with ⌘V."
        }
        await refresh()
    }

    func copyRefused() {
        host.copyOffered()
        notice = "Copied. Paste it with ⌘V."
    }

    func openPicker() { host.openPicker() }

    private func rows(for filter: LibraryFilter, matching text: String) async -> [SnippetRow] {
        guard case .results(let hits) = await library.search(query: text, filter: filter) else { return [] }
        return hits.prefix(Self.rowLimit).map { SnippetRow($0.snippet) }
    }
}
