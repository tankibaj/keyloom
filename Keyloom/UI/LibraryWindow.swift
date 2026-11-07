import SwiftUI

/// The smallest library window: wide enough for the sidebar, the list and the editor with its toolbar.
enum LibraryWindowMetrics {
    static let minimumSize = CGSize(width: 860, height: 520)

    /// A frame restored from an earlier session may be smaller than the content; it is grown, never shrunk.
    static func clamped(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width, minimumSize.width), height: max(size.height, minimumSize.height))
    }
}

/// The single library window: opening and failure states, then sidebar, list and detail.
struct LibraryWindow: View {
    @Bindable var model: AppModel

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
                    Button("Try Again") { Task { await model.open() } }.keyboardShortcut(.defaultAction)
                }
            case .ready(_, let library):
                LibrarySplitView(model: model, library: library)
            }
        }
        .frame(minWidth: LibraryWindowMetrics.minimumSize.width, minHeight: LibraryWindowMetrics.minimumSize.height)
        .background(WindowCloseGuardInstaller(model: model))
        .task { await model.open() }
    }
}

private struct LibrarySplitView: View {
    @Bindable var model: AppModel
    @Bindable var library: LibraryViewModel
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
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { Task { await model.requestCancel() } }.keyboardShortcut(.cancelAction)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { Task { await model.saveEditor() } }.disabled(!editor.canSave)
                                .accessibilityIdentifier("editor.save")
                        }
                    }
            } else {
                ContentUnavailableView("Select a Snippet", systemImage: "text.cursor",
                                       description: Text("Choose a snippet from the list, or create one with New Snippet."))
            }
        }
        .searchable(text: $library.query, placement: .toolbar, prompt: "Search snippets")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequests) { searchFocused = true }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Snippet", systemImage: "square.and.pencil") { Task { await model.requestNewSnippet() } }
                    .help("New Snippet")
                    .accessibilityIdentifier("library.newSnippet")
            }
        }
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
