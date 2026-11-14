import Foundation

/// The window side of the prompt, so the coordinator is testable without AppKit.
@MainActor
protocol PromptPresenting: AnyObject {
    func show(_ model: ArgumentPromptModel)
    func close()
}

/// The UI's `ArgumentPrompting`: shows the prompt, waits for Confirm or Cancel, and answers nil at once when the
/// host cancels the task (pause, stop, permission loss). One prompt at a time: a second request is refused, so
/// the user is never asked two questions about text that is about to change. The window closes before the
/// answer is returned; focus return is the host's job (see `ArgumentPrompting`).
@MainActor
final class ArgumentPromptCoordinator: ArgumentPrompting {
    private let presenter: PromptPresenting
    private let title: @MainActor (UUID) async -> String?
    private var isPresenting = false

    init(presenter: PromptPresenting, title: @escaping @MainActor (UUID) async -> String?) {
        self.presenter = presenter
        self.title = title
    }

    func promptForArguments(for snippetID: UUID, requirements: [ArgumentRequirement]) async -> [String: String]? {
        guard !isPresenting, !Task.isCancelled else { return nil }
        isPresenting = true
        let heading = await title(snippetID).map { "Insert “\($0)”" } ?? "Insert snippet"
        let model = ArgumentPromptModel(title: heading, requirements: requirements)
        guard !Task.isCancelled else {
            isPresenting = false
            return nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                model.onFinish = { [self] answers in
                    isPresenting = false
                    presenter.close()
                    continuation.resume(returning: answers)
                }
                presenter.show(model)
            }
        } onCancel: {
            Task { @MainActor in model.cancel() }
        }
    }
}
