import StillCore
import SwiftUI

@main
struct StillDesktopApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(StillApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        WindowGroup {
            AppContainer(model: model)
                .onAppear { applicationDelegate.model = model }
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            StillCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
