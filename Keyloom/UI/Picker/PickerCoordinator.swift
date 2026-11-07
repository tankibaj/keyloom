import AppKit
import Foundation

/// The picker window, so the coordinator is testable without AppKit.
@MainActor
protocol PickerPanelPresenting: AnyObject {
    func show(_ model: PickerModel)
    func hide()
}

/// Remembers the app that was frontmost before Keyloom activated, and hands focus back to it.
@MainActor
protocol FocusRestoring: AnyObject {
    func rememberFrontmost()
    func restore()
}

/// The UI's `PickerPresenting`. The host captures the destination first and calls `presentPicker` with it; the
/// frontmost app is noted before Keyloom comes forward and the destination lives in the session, so a later
/// Insert goes where the user was, not where focus is now.
@MainActor
final class PickerCoordinator: PickerPresenting {
    private(set) var model: PickerModel?
    private(set) var inserter: SnippetInserter?

    private let library: SnippetLibrary
    private let panel: PickerPanelPresenting
    private let focus: FocusRestoring
    private let prompter: ArgumentPrompting
    private let environment: @MainActor () -> RenderEnvironment
    /// Set only while `captureDestination` runs, to take the destination instead of showing the picker.
    private var captureHandler: ((CapturedDestination?) -> Void)?
    private weak var host: InputHostController?

    init(library: SnippetLibrary, panel: PickerPanelPresenting, focus: FocusRestoring, prompter: ArgumentPrompting,
         environment: @escaping @MainActor () -> RenderEnvironment = SnippetInserter.liveEnvironment) {
        self.library = library
        self.panel = panel
        self.focus = focus
        self.prompter = prompter
        self.environment = environment
    }

    /// The host needs this coordinator at construction, so the host is attached afterwards.
    func attach(_ host: InputHostController) {
        self.host = host
        inserter = SnippetInserter(library: library, host: host, prompter: prompter, environment: environment)
    }

    func presentPicker(destination: CapturedDestination?) {
        if let captureHandler {
            captureHandler(destination)
            return
        }
        guard let inserter else { return }
        focus.rememberFrontmost()
        let session = PickerModel(library: library, inserter: inserter, destination: destination)
        session.onHide = { [weak self] in self?.panel.hide() }
        session.onReshow = { [weak self, weak session] in
            if let self, let session { panel.show(session) }
        }
        session.onReturnFocus = { [weak self] in self?.focus.restore() }
        model = session
        panel.show(session)
    }

    /// For the menu bar: the field focused right now, captured by the host, without opening the picker.
    func captureDestination() -> CapturedDestination? {
        guard let host else { return nil }
        focus.rememberFrontmost()
        var captured: CapturedDestination?
        captureHandler = { captured = $0 }
        defer { captureHandler = nil }
        host.openPicker()
        return captured
    }

    func restoreFocus() { focus.restore() }
}

@MainActor
final class WorkspaceFocusRestorer: FocusRestoring {
    private var previous: NSRunningApplication?

    func rememberFrontmost() {
        let front = NSWorkspace.shared.frontmostApplication
        previous = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previous : front
    }

    func restore() { previous?.activate() }
}
