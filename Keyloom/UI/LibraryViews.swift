import AppKit
import SwiftUI

/// Emoji as text, SF Symbol as an image in its chosen color (secondary when it has none); an unknown symbol name
/// falls back so a row never renders empty.
struct SnippetIconView: View {
    let icon: SnippetIcon

    var body: some View {
        switch icon {
        case .emoji(let emoji):
            Text(emoji)
        case .symbol(let name, let color):
            Image(systemName: NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "doc.text" : name)
                .foregroundStyle(color.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
        }
    }
}

/// The icon on a small rounded tile, tinted by the icon's own color (neutral for emoji and uncolored symbols).
struct SnippetIconTile: View {
    let icon: SnippetIcon
    var size: CGFloat = 28

    private var tint: Color {
        if case .symbol(_, let color?) = icon { return color.color }
        return .secondary
    }

    var body: some View {
        SnippetIconView(icon: icon)
            .font(.system(size: size * 0.5))
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The sidebar footer: whether typing expansion works right now. Needs Accessibility is a button that opens the fix.
struct ExpansionStatusFooter: View {
    let status: ExpansionStatus
    let openAccessibility: () -> Void

    private var color: Color {
        switch status {
        case .on: .green
        case .paused: .secondary
        case .needsAccessibility: .orange
        }
    }

    var body: some View {
        let content = HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(status.title).font(.callout)
            Spacer(minLength: 0)
            if status == .needsAccessibility { Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary) }
        }
        .foregroundStyle(status == .needsAccessibility ? .primary : .secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        Group {
            if status == .needsAccessibility {
                Button(action: openAccessibility) { content }
                    .buttonStyle(.plain)
                    .help("Open Privacy & Security settings to turn on Accessibility")
                    .accessibilityLabel("Needs Accessibility. Open System Settings")
            } else {
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(status.title)
            }
        }
        .accessibilityIdentifier("library.expansionStatus")
    }
}

struct SidebarView: View {
    @Bindable var library: LibraryViewModel
    var status: ExpansionStatus?
    var openAccessibility: () -> Void = {}

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
            Section {
                Label("Recently Deleted", systemImage: "trash").tag(SidebarItem.recentlyDeleted)
            }
        }
        .accessibilityLabel("Library navigation")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let status { ExpansionStatusFooter(status: status, openAccessibility: openAccessibility) }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
    }
}

/// Name, an Off pill when expansion is off, the keyword as a chip on the right, and one line of the body below.
struct SnippetRowView: View {
    let row: SnippetRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SnippetIconTile(icon: row.icon)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).fontWeight(.medium).lineLimit(1)
                    if row.keyword != nil, !row.enabled {
                        Text("Off")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .background(.quaternary, in: Capsule())
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    if row.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    if let keyword = row.keyword { KeywordChip(keyword: keyword) }
                }
                if !row.preview.isEmpty {
                    Text(row.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .opacity(row.keyword != nil && !row.enabled ? 0.6 : 1)
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

/// The keyword drawn like a keycap: monospaced, on a quiet fill. It truncates before the name does.
struct KeywordChip: View {
    let keyword: String

    var body: some View {
        Text(keyword)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .frame(maxWidth: 110)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct SnippetListView: View {
    @Bindable var library: LibraryViewModel
    let select: @MainActor (UUID?) -> Void
    let newSnippet: @MainActor () -> Void
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        List(selection: Binding<UUID?>(get: { library.selection }, set: select)) {
            if library.sidebarItem == .recentlyDeleted {
                ForEach(library.deletedRows) { row in DeletedRowView(row: row, library: library) }
            } else {
                ForEach(library.rows) { row in
                    SnippetRowView(row: row)
                        .tag(row.id)
                        .contextMenu { SnippetActions(library: library, id: row.id, pinned: row.pinned) }
                }
            }
        }
        .accessibilityLabel(library.sidebarItem == .recentlyDeleted ? "Recently deleted snippets" : "Snippets")
        .onDeleteCommand {
            if library.sidebarItem != .recentlyDeleted, let id = library.selection { Task { await library.delete(id: id) } }
        }
        .overlay {
            if let state = library.emptyState {
                LibraryEmptyView(state: state, library: library, newSnippet: newSnippet)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let notice = library.notice {
                Text(notice)
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                    .accessibilityAddTraits(.isStaticText)
                    .onAppear { AccessibilityNotification.Announcement(notice).post() }
            }
        }
        .onAppear { library.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in library.undoManager = manager }
        .navigationTitle(library.title)
        .navigationSubtitle(library.subtitle)
        .toolbar {
            // Over the list: what makes or orders its rows.
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Sort By", selection: $library.sort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Choose how snippets are ordered")
                .accessibilityIdentifier("library.sort")
                Button("New Snippet", systemImage: "square.and.pencil", action: newSnippet)
                    .help("Create a snippet (Command-N)")
                    .accessibilityIdentifier("library.newSnippet")
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
    }
}

struct DeletedRowView: View {
    let row: DeletedRow
    let library: LibraryViewModel

    var body: some View {
        HStack(spacing: 10) {
            SnippetIconView(icon: row.icon).font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1)
                Text("Deleted \(row.deletedAt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Restore") { Task { await library.restoreDeleted(id: row.id) } }
                .accessibilityLabel("Restore \(row.name)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .contextMenu { Button("Restore") { Task { await library.restoreDeleted(id: row.id) } } }
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
        case .emptyTrash:
            ContentUnavailableView("Nothing Deleted", systemImage: "trash",
                                   description: Text("Deleted snippets stay here so you can bring them back."))
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
