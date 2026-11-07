import SwiftUI

@main
struct KeyloomApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window(AppIdentity.name, id: "library") {
            LibraryWindow(model: model)
        }
        .commands { LibraryCommands(model: model) }
        // WP4 slices D-E attach here: MenuBarExtra (pinned popover), the picker panel and the Settings scene.
    }
}
