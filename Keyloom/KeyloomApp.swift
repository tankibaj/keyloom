import SwiftUI

@main
struct KeyloomApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(AppIdentity.name, id: "library") {
            LibraryWindow(model: model)
                .onAppear {
                    appDelegate.model = model
                    model.quitAction = { NSApp.terminate(nil) }
                }
        }
        .commands { LibraryCommands(model: model) }
        // WP4 slices D-E attach here: MenuBarExtra (pinned popover), the picker panel and the Settings scene.
    }
}
