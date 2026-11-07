import Foundation
import Observation

/// Root state of the library window. Later surfaces (menu-bar popover, picker, Settings) read the same model:
/// `library` for data, `libraryModel` for the list state, `newSnippet()` for navigation.
@MainActor @Observable
final class AppModel {
    enum Phase {
        case opening
        case ready(SnippetLibrary, LibraryViewModel)
        case failed(String)
    }

    let dataDirectory: URL
    private(set) var phase = Phase.opening
    /// Bumped by Find; the toolbar search field takes focus when it changes.
    private(set) var searchFocusRequests = 0

    init(dataDirectory: URL = DataLocation.resolve()) {
        self.dataDirectory = dataDirectory
    }

    var library: SnippetLibrary? {
        if case .ready(let library, _) = phase { library } else { nil }
    }

    var libraryModel: LibraryViewModel? {
        if case .ready(_, let model) = phase { model } else { nil }
    }

    /// Opens the library and loads the list. Runs again after a failure (Try Again).
    func open() async {
        if library != nil { return }
        phase = .opening
        do {
            let library = try await DataLocation.openLibrary(in: dataDirectory)
            let model = LibraryViewModel(library: library)
            await model.refresh()
            phase = .ready(library, model)
        } catch {
            phase = .failed(UserMessage.describe(error))
        }
    }

    func requestSearchFocus() { searchFocusRequests += 1 }

    func newSnippet() async {
        guard let model = libraryModel else { return }
        guard let created = await model.attempt({
            try await model.library.create(name: "Untitled Snippet", icon: .symbol("text.bubble"), keyword: nil,
                                           template: Document(paragraphs: []))
        }) else { return }
        await model.refresh()
        model.selection = created.id
    }
}
