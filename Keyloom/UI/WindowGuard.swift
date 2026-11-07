import AppKit
import SwiftUI

/// Routes Quit through the dirty-edit guard: while the sheet is up the app stays; the sheet's choice quits again.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return model.shouldTerminate() ? .terminateNow : .terminateCancel
    }
}

/// Asks `shouldClose` before the window closes (red button, Cmd-W). Every other delegate call is forwarded to the
/// delegate SwiftUI installed, so window behavior is otherwise unchanged.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    // Read only by the Objective-C forwarding hooks below, which AppKit calls on the main thread.
    nonisolated(unsafe) private weak var original: NSWindowDelegate?
    private let shouldClose: @MainActor () -> Bool

    @MainActor
    init(replacing original: NSWindowDelegate?, shouldClose: @escaping @MainActor () -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose() }

    override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }

    override func forwardingTarget(for selector: Selector!) -> Any? { original }
}

/// Invisible view that installs the guard on its window and tells the model how to close it afterwards.
struct WindowCloseGuardInstaller: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView { InstallerView(model: model) }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class InstallerView: NSView {
        let model: AppModel
        private var closeGuard: WindowCloseGuard?

        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            guard let window, closeGuard == nil else { return }
            let model = model
            let closeGuard = WindowCloseGuard(replacing: window.delegate) { model.shouldCloseWindow() }
            self.closeGuard = closeGuard
            window.delegate = closeGuard
            model.closeWindowAction = { [weak window] in window?.close() }
        }
    }
}
