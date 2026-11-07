import SwiftUI

/// The smallest library window: wide enough for the sidebar, the list and the editor, and for the whole toolbar
/// (Sort, New, Pin/Duplicate/Delete, search) to show without the overflow menu.
enum LibraryWindowMetrics {
    static let minimumSize = CGSize(width: 1020, height: 520)

    /// A frame restored from an earlier session may be smaller than the content; it is grown, never shrunk.
    static func clamped(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width, minimumSize.width), height: max(size.height, minimumSize.height))
    }
}

/// The single library window: opening and failure states, then sidebar, list and detail.
struct LibraryWindow: View {
    let environment: AppEnvironment
    private var model: AppModel { environment.model }

    func openLibrary() async {
        await environment.start()
    }

    var body: some View {
        Group {
            switch model.phase {
            case .opening:
                ProgressView("Opening library…")
            case .failed(let message):
                ContentUnavailableView {
                    Label("The Library Could Not Be Opened", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await openLibrary() } }.keyboardShortcut(.defaultAction)
                }
            case .ready(_, let library):
                LibrarySplitView(model: model, library: library, tagColors: environment.tagColors,
                                 status: environment.services.map { ExpansionStatus($0.host.status) })
            }
        }
        .frame(minWidth: LibraryWindowMetrics.minimumSize.width, minHeight: LibraryWindowMetrics.minimumSize.height)
        .background(WindowCloseGuardInstaller(model: model))
        .task { await openLibrary() }
    }
}

private struct LibrarySplitView: View {
    @Bindable var model: AppModel
    @Bindable var library: LibraryViewModel
    let tagColors: TagColors
    let status: ExpansionStatus?
    @Environment(\.openURL) private var openURL
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView(library: library, tagColors: tagColors, status: status,
                        openAccessibility: { openURL(ExpansionStatus.accessibilitySettingsURL) })
        } content: {
            SnippetListView(library: library, select: { id in Task { await model.requestSelection(id) } },
                            newSnippet: { Task { await model.requestNewSnippet() } })
        } detail: {
            Group {
                if let editor = model.editor {
                    EditorView(editor: editor, save: { Task { await model.saveEditor() } },
                               availableTags: library.tags.map(\.tag), tagColors: tagColors)
                        .id(ObjectIdentifier(editor))
                        .background { closeEditorShortcut }
                } else {
                    ContentUnavailableView("Select a Snippet", systemImage: "text.cursor",
                                           description: Text("Choose a snippet from the list, or create one with New Snippet."))
                }
            }
            .toolbar { trailingToolbar(editor: model.editor) }
        }
        .searchable(text: $library.query, placement: .toolbar, prompt: "Search snippets")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequests) { searchFocused = true }
        .task { await library.observeChanges() }
        .confirmationDialog(dismissalTitle, isPresented: Binding(get: { model.pendingDismissal != nil }, set: { _ in }), titleVisibility: .visible) {
            Button("Save") { Task { await model.resolvePending(.save) } }.keyboardShortcut(.defaultAction)
            Button("Discard Changes", role: .destructive) { Task { await model.resolvePending(.discard) } }
            Button("Keep Editing", role: .cancel) { Task { await model.resolvePending(.keepEditing) } }
        } message: {
            Text("Your changes are lost if you don’t save them.")
        }
        .alert("Couldn’t Complete That", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    /// One trailing cluster beside the search field, nothing floating mid-bar: what makes or orders the list (Sort,
    /// New), then, once a snippet is saved, what acts on it (Pin, Duplicate, Delete; the row's pin state tells Pin
    /// from Unpin). Save and Revert live in the editor's own action bar; the expansion status is a quiet line at the
    /// foot of the sidebar.
    @ToolbarContentBuilder
    private func trailingToolbar(editor: EditorViewModel?) -> some ToolbarContent {
        ToolbarSpacer(.flexible)
        ToolbarItemGroup {
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
            Button("New Snippet", systemImage: "square.and.pencil") { Task { await model.requestNewSnippet() } }
                .help("Create a snippet (Command-N)")
                .accessibilityIdentifier("library.newSnippet")
        }
        if let editor, case .existing(let saved) = editor.target {
            let pinned = library.rows.first { $0.id == saved }?.pinned ?? false
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                    Task { await library.togglePin(id: saved) }
                }
                .help(pinned ? "Unpin this snippet (Shift-Command-P)" : "Pin this snippet (Shift-Command-P)")
                .disabled(!library.rows.contains { $0.id == saved })
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    Task { await library.duplicate(id: saved) }
                }
                .help("Make a copy of this snippet (Command-D)")
                Button("Delete", systemImage: "trash") {
                    Task { await library.delete(id: saved) }
                }
                .help("Move this snippet to Recently Deleted")
            }
        }
    }

    /// Escape closes the editor through the unsaved-changes confirmation. It has no visible button of its own.
    private var closeEditorShortcut: some View {
        Button("Close Editor") { Task { await model.requestCancel() } }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private var dismissalTitle: String {
        let name = model.editor?.draft.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Save changes to this snippet?" : "Save changes to “\(name)”?"
    }
}

struct LibraryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Snippet") { Task { await model.requestNewSnippet() } }
                .keyboardShortcut("n")
                .disabled(model.libraryModel == nil)
            Button("Save Snippet") { Task { await model.saveEditor() } }
                .keyboardShortcut("s")
                .disabled(model.editor?.canSave != true)
        }
        CommandGroup(after: .newItem) {
            let library = model.libraryModel
            let row = library.flatMap { model in model.rows.first { $0.id == model.selection } }
            Button("Duplicate Snippet") { if let library, let id = row?.id { Task { await library.duplicate(id: id) } } }
                .keyboardShortcut("d")
                .disabled(row == nil)
            Button(row?.pinned == true ? "Unpin Snippet" : "Pin Snippet") {
                if let library, let id = row?.id { Task { await library.togglePin(id: id) } }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(row == nil)
            Button("Delete Snippet") { if let library, let id = row?.id { Task { await library.delete(id: id) } } }
                .disabled(row == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find Snippets") { model.requestSearchFocus() }
                .keyboardShortcut("f")
                .disabled(model.libraryModel == nil)
        }
    }
}
