import SwiftUI

@main
struct KeyloomApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Keyloom core ABI \(KeyloomCore.abiVersion)")
                .padding()
        }
    }
}
