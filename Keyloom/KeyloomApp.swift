import SwiftUI

@main
struct KeyloomApp: App {
    @State private var environment: AppEnvironment
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let environment = AppEnvironment()
        _environment = State(initialValue: environment)
        // The host and the menu bar belong to the resident app, not to the library window being open.
        Task { await environment.start() }
    }

    var body: some Scene {
        Window(AppIdentity.name, id: "library") {
            LibraryWindow(model: environment.model)
                .onAppear {
                    appDelegate.model = environment.model
                    appDelegate.shutdown = { [environment] in await environment.shutdown() }
                    environment.model.quitAction = { AppDelegate.requestTermination() }
                }
        }
        .windowResizability(.contentMinSize)
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
                .modifier(OpenLibraryAtLaunch())
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(settings: environment.services?.settings, snapshotError: environment.model.snapshotError)
        }
    }
}

/// The menu-bar label exists from launch, so it can open the library window once, as a plain app would.
private struct OpenLibraryAtLaunch: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @State private var opened = false

    func body(content: Content) -> some View {
        content.task {
            guard !opened else { return }
            opened = true
            openWindow(id: "library")
        }
    }
}
