import AppKit
import SwiftUI

/// Emoji as text, SF Symbol as an image; an unknown symbol name falls back so a row never renders empty.
struct SnippetIconView: View {
    let icon: SnippetIcon

    var body: some View {
        switch icon {
        case .emoji(let emoji):
            Text(emoji)
        case .symbol(let name):
            Image(systemName: NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "doc.text" : name)
                .foregroundStyle(.secondary)
        }
    }
}

struct SidebarView: View {
    @Bindable var library: LibraryViewModel

    var body: some View {
        List(selection: Binding<SidebarItem?>(get: { library.sidebarItem }, set: { if let item = $0 { library.sidebarItem = item } })) {
            Section("Library") {
                Label("All Snippets", systemImage: "text.bubble").badge(library.counts.all).tag(SidebarItem.all)
                Label("Recently Used", systemImage: "clock").badge(library.counts.recentlyUsed).tag(SidebarItem.recentlyUsed)
                Label("Pinned", systemImage: "pin").badge(library.counts.pinned).tag(SidebarItem.pinned)
            }
            if !library.tags.isEmpty {
                Section("Tags") {
                    ForEach(library.tags, id: \.tag) { summary in
                        Label(summary.tag, systemImage: "tag").badge(summary.count).tag(SidebarItem.tag(summary.tag))
                    }
                }
            }
        }
        .accessibilityLabel("Library navigation")
        .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
    }
}

struct SnippetRowView: View {
    let row: SnippetRow

    var body: some View {
        HStack(spacing: 10) {
            SnippetIconView(icon: row.icon)
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1)
                if let keyword = row.keyword {
                    HStack(spacing: 4) {
                        Text(keyword).font(.caption.monospaced())
                        if !row.enabled { Text("Off").font(.caption) }
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if row.pinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

struct SnippetListView: View {
    @Bindable var library: LibraryViewModel
    let select: @MainActor (UUID?) -> Void
    let newSnippet: @MainActor () -> Void
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        List(selection: Binding<UUID?>(get: { library.selection }, set: select)) {
            ForEach(library.rows) { row in
                SnippetRowView(row: row)
                    .tag(row.id)
                    .contextMenu { SnippetActions(library: library, id: row.id, pinned: row.pinned) }
            }
        }
        .accessibilityLabel("Snippets")
        .onDeleteCommand {
            if let id = library.selection { Task { await library.delete(id: id) } }
        }
        .overlay {
            if let state = library.emptyState {
                LibraryEmptyView(state: state, library: library, newSnippet: newSnippet)
            }
        }
        .onAppear { library.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in library.undoManager = manager }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
    }
}

/// Duplicate, pin and delete: the row context menu and the File menu share it.
struct SnippetActions: View {
    let library: LibraryViewModel
    let id: UUID
    let pinned: Bool

    var body: some View {
        Button("Duplicate", systemImage: "plus.square.on.square") { Task { await library.duplicate(id: id) } }
        Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") { Task { await library.togglePin(id: id) } }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { Task { await library.delete(id: id) } }
    }
}

struct LibraryEmptyView: View {
    let state: LibraryEmptyState
    let library: LibraryViewModel
    let newSnippet: () -> Void

    var body: some View {
        switch state {
        case .emptyLibrary:
            ContentUnavailableView {
                Label("No Snippets Yet", systemImage: "text.badge.plus")
            } description: {
                Text("Create a snippet to expand it by keyword or insert it from the picker.")
            } actions: {
                Button("New Snippet", action: newSnippet).keyboardShortcut(.defaultAction)
            }
        case .noResults(let query):
            ContentUnavailableView {
                Label("No Results for “\(query)”", systemImage: "magnifyingglass")
            } description: {
                Text("Check the spelling or try a name, keyword, tag or text from the body.")
            } actions: {
                Button("Clear Search") { Task { await library.clearSearch() } }.keyboardShortcut(.defaultAction)
            }
        case .emptyFilter(let item):
            ContentUnavailableView {
                Label(Self.title(for: item), systemImage: "tray")
            } description: {
                Text(Self.hint(for: item))
            } actions: {
                Button("Show All Snippets") { Task { await library.showAll() } }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private static func title(for item: SidebarItem) -> String {
        switch item {
        case .pinned: "Nothing Pinned Yet"
        case .recentlyUsed: "Nothing Used Yet"
        default: "No Snippets Here"
        }
    }

    private static func hint(for item: SidebarItem) -> String {
        switch item {
        case .pinned: "Pin a snippet from its context menu to keep it handy."
        case .recentlyUsed: "Snippets appear here after they expand or are inserted."
        default: "No snippet has this tag any more."
        }
    }
}
