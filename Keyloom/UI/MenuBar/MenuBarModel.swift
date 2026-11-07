import AppKit
import Foundation
import Observation

/// The menu-bar popover: pinned and recently used snippets (searchable), pause, the picker and the host's last
/// refusal. Reads the host's observable status, so the pause switch and the shortcut warning are never stale.
/// Picking a snippet inserts it into the field focused when it was clicked, or copies it when no field can be used.
@MainActor @Observable
final class MenuBarModel {
    /// What the status row says. One state, derived from the host: Accessibility first, then pause.
    enum Status: Equatable {
        case on, paused, needsAccessibility

        var title: String {
            switch self {
            case .on: "Expansion on"
            case .paused: "Paused"
            case .needsAccessibility: "Needs Accessibility"
            }
        }
    }

    /// A snippet row as the popover draws it: the keyword chip and the ⌘1–9 shortcut (nil past the ninth row).
    struct PopoverRow: Identifiable, Equatable {
        let row: SnippetRow
        let number: Int?
        var id: UUID { row.id }
        var chip: String? { row.keyword }
        var shortcutHint: String? { number.map { "⌘\($0)" } }
    }

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

    var status: Status {
        if !host.status.permissions.accessibility { return .needsAccessibility }
        return host.status.isPaused ? .paused : .on
    }

    var needsAccessibility: Bool { status == .needsAccessibility }

    /// New Snippet and Open Picker are for a working Keyloom; without Accessibility the menu stays at Library, Settings, Quit.
    var showsExpansionCommands: Bool { !needsAccessibility }

    /// The status row's switch: on means expanding. Off when paused or when Accessibility is missing.
    var isExpanding: Bool {
        get { status == .on }
        set { host.setPaused(!newValue) }
    }

    /// The picker shortcut, shown as a hint in the search field; nil if it is not registered.
    var pickerShortcutHint: String? {
        if case .registered(let config) = host.status.shortcut { ShortcutDisplay.string(for: config) } else { nil }
    }

    /// Pinned then recent rows numbered ⌘1 to ⌘9 in the order they are drawn.
    var pinnedItems: [PopoverRow] { Self.numbered(pinned, offset: 0) }
    var recentItems: [PopoverRow] { Self.numbered(recents, offset: pinned.count) }

    nonisolated static func numbered(_ rows: [SnippetRow], offset: Int) -> [PopoverRow] {
        rows.enumerated().map { PopoverRow(row: $1, number: offset + $0 < 9 ? offset + $0 + 1 : nil) }
    }

    /// Inserts the snippet shown under ⌘<number>, if any.
    func insert(number: Int) async {
        guard let item = (pinnedItems + recentItems).first(where: { $0.number == number }) else { return }
        await insert(item.id)
    }

    func openAccessibilitySettings() { NSWorkspace.shared.open(ExpansionSettingsModel.accessibilitySettingsURL) }

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
