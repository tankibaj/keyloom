import SwiftUI

/// The smallest library window: wide enough for the sidebar, the list and the editor, and for the whole toolbar
/// (status chip, Pin/Duplicate/Delete, edited caption, Revert, Save) to show without the overflow menu.
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
                LibrarySplitView(model: model, library: library,
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
    let status: ExpansionStatus?
    @Environment(\.openURL) private var openURL
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView(library: library)
        } content: {
            SnippetListView(library: library, select: { id in Task { await model.requestSelection(id) } },
                            newSnippet: { Task { await model.requestNewSnippet() } })
        } detail: {
            if let editor = model.editor {
                EditorView(editor: editor)
                    .id(ObjectIdentifier(editor))
                    .toolbar { detailToolbar(editor) }
                    .background { closeEditorShortcut }
            } else {
                ContentUnavailableView("Select a Snippet", systemImage: "text.cursor",
                                       description: Text("Choose a snippet from the list, or create one with New Snippet."))
            }
        }
        .toolbar {
            // Always visible, at the top of the window: nothing critical at the bottom of the sidebar.
            if let status {
                ToolbarItem(placement: .primaryAction) {
                    ExpansionStatusChip(status: status, openAccessibility: { openURL(ExpansionStatus.accessibilitySettingsURL) })
                }
            }
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

    /// Over the detail: what acts on the open snippet, then the one prominent action. Pin, Duplicate and Delete
    /// need a saved snippet; the row's pin state tells Pin from Unpin.
    @ToolbarContentBuilder
    private func detailToolbar(_ editor: EditorViewModel) -> some ToolbarContent {
        let saved: UUID? = if case .existing(let id) = editor.target { id } else { nil }
        let pinned = saved.flatMap { id in library.rows.first { $0.id == id }?.pinned } ?? false
        ToolbarSpacer(.flexible)
        ToolbarItemGroup {
            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                if let saved { Task { await library.togglePin(id: saved) } }
            }
            .help(pinned ? "Unpin this snippet (Shift-Command-P)" : "Pin this snippet (Shift-Command-P)")
            .disabled(saved == nil || !library.rows.contains { $0.id == saved })
            Button("Duplicate", systemImage: "plus.square.on.square") {
                if let saved { Task { await library.duplicate(id: saved) } }
            }
            .help("Make a copy of this snippet (Command-D)")
            .disabled(saved == nil)
            Button("Delete", systemImage: "trash") {
                if let saved { Task { await library.delete(id: saved) } }
            }
            .help("Move this snippet to Recently Deleted")
            .disabled(saved == nil)
        }
        ToolbarSpacer(.fixed)
        if let caption = editor.dirtyCaption {
            ToolbarItem {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("editor.dirtyCaption")
            }
        }
        ToolbarItem {
            Button("Revert") { editor.revert() }
                .disabled(!editor.isDirty)
                .help("Discard the changes since the last save")
                .accessibilityIdentifier("editor.revert")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { Task { await model.saveEditor() } }
                .buttonStyle(.borderedProminent)
                .disabled(!editor.canSave)
                .help("Save this snippet (Command-S)")
                .accessibilityIdentifier("editor.save")
        }
    }

    /// Escape closes the editor through the unsaved-changes confirmation. It has no toolbar button: Revert owns
    /// the visible slot, and a third button would overflow the toolbar at the minimum window width.
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
