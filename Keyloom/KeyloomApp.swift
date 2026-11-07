import SwiftUI

@main
struct KeyloomApp: App {
    @State private var environment = AppEnvironment()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(AppIdentity.name, id: "library") {
            LibraryWindow(model: environment.model)
                .onAppear {
                    appDelegate.model = environment.model
                    environment.model.quitAction = { NSApp.terminate(nil) }
                }
                .task { await environment.start() }
        }
        .commands { LibraryCommands(model: environment.model) }
        MenuBarExtra {
            if let menuBar = environment.services?.menuBar {
                MenuBarView(model: menuBar, app: environment.model)
            } else {
                ProgressView("Starting…").padding()
            }
        } label: {
            Image(systemName: environment.services?.menuBar.symbolName ?? "text.cursor")
                .accessibilityLabel(AppIdentity.name)
        }
        .menuBarExtraStyle(.window)
        // WP4 slice E attaches the Settings scene here.
    }
}
