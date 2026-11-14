import AppKit
import Foundation

/// Renders a stored snippet for the picker and the menu bar (asking for arguments when it needs them) and hands
/// it to the host: insertion into a destination captured earlier, or an explicit Copy. Insertion goes through
/// `InputHostController.insert`, which re-verifies the field and records usage. Rendered text and answers pass
/// through here only: nothing is stored or logged.
@MainActor
final class SnippetInserter {
    private let library: SnippetLibrary
    private let host: InputHostController
    private let prompter: ArgumentPrompting
    private let environment: @MainActor () -> RenderEnvironment

    init(library: SnippetLibrary, host: InputHostController, prompter: ArgumentPrompting,
         environment: @escaping @MainActor () -> RenderEnvironment) {
        self.library = library
        self.host = host
        self.prompter = prompter
        self.environment = environment
    }

    /// What the preview pane shows: arguments take their default, first choice or a stand-in, and the clipboard
    /// is never read.
    func preview(snippetID: UUID) async -> Preview {
        guard let snippet = await library.snippet(id: snippetID) else { return .unavailable("This snippet is no longer available.") }
        let samples = Dictionary(uniqueKeysWithValues: TemplateRenderer.requiredArguments(in: snippet.template).map {
            ($0.name, $0.defaultValue ?? $0.choices.first ?? "‹\($0.name)›")
        })
        do {
            guard case .rendered(let rendered) = try library.preview(for: snippet.template, arguments: samples,
                                                                     environment: EditorViewModel.liveEnvironment()) else {
                return .unavailable("This snippet could not be previewed.")
            }
            return .rendered(rendered)
        } catch {
            return .unavailable(UserMessage.describe(error))
        }
    }

    /// nil: the user cancelled the argument prompt, nothing was touched.
    func insert(snippetID: UUID, into destination: CapturedDestination) async -> InsertionOutcome? {
        switch await render(snippetID) {
        case .cancelled: nil
        case .failed(let outcome): outcome
        case .rendered(let rendered): await host.insert(rendered, into: destination, route: .plain, snippetID: snippetID)
        }
    }

    /// nil: cancelled at the prompt. Copy is user-initiated and never restored (host contract).
    func copy(snippetID: UUID) async -> InsertionOutcome? {
        switch await render(snippetID) {
        case .cancelled:
            return nil
        case .failed(let outcome):
            return outcome
        case .rendered(let rendered):
            host.copy(rendered)
            return .copied
        }
    }

    private enum Rendering {
        case rendered(RenderedSnippet)
        case cancelled
        case failed(InsertionOutcome)
    }

    private func render(_ snippetID: UUID) async -> Rendering {
        guard let snippet = await library.snippet(id: snippetID) else { return .failed(.failedClosed(.snippetUnavailable)) }
        do {
            var expansion = try library.preview(for: snippet.template, environment: environment())
            if case .needsArguments(let requirements) = expansion {
                guard let answers = await prompter.promptForArguments(for: snippetID, requirements: requirements) else { return .cancelled }
                expansion = try library.preview(for: snippet.template, arguments: answers, environment: environment())
            }
            guard case .rendered(let rendered) = expansion else { return .failed(.failedClosed(.argumentsIncomplete)) }
            return .rendered(rendered)
        } catch {
            return .failed(.failedClosed(.argumentsIncomplete))
        }
    }

    /// Clipboard text is read lazily, only when a template uses `{clipboard}`, and always on the main thread.
    static func liveEnvironment() -> RenderEnvironment {
        let pasteboard = SystemPasteboard()
        return RenderEnvironment(date: Date(), timeZone: .current, locale: .current, makeUUID: { UUID() }) {
            if Thread.isMainThread { return MainActor.assumeIsolated { pasteboard.plainText() } }
            return DispatchQueue.main.sync { MainActor.assumeIsolated { pasteboard.plainText() } }
        }
    }
}
