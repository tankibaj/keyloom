import SwiftUI

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
        .frame(minWidth: 860, minHeight: 520)
        .task { await model.open() }
    }
}

private struct LibrarySplitView: View {
    let model: AppModel
    @Bindable var library: LibraryViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView(library: library)
        } content: {
            SnippetListView(library: library, select: { library.selection = $0 }, newSnippet: { Task { await model.newSnippet() } })
        } detail: {
            ContentUnavailableView("Select a Snippet", systemImage: "text.cursor",
                                   description: Text("Choose a snippet from the list, or create one with New Snippet."))
        }
        .searchable(text: $library.query, placement: .toolbar, prompt: "Search snippets")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequests) { searchFocused = true }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Snippet", systemImage: "square.and.pencil") { Task { await model.newSnippet() } }
                    .help("New Snippet")
            }
        }
        .task { await library.observeChanges() }
        .alert("Couldn’t Complete That", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }
}

struct LibraryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Snippet") { Task { await model.newSnippet() } }
                .keyboardShortcut("n")
                .disabled(model.libraryModel == nil)
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
