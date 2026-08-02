import StillCore
import SwiftUI

@main
struct StillDesktopApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(StillApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        Window("Still", id: "main") {
            AppContainer(model: model)
                .onAppear { applicationDelegate.model = model }
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Install from Local File…") {
                    model.destination = .install
                    model.chooseLocalInstaller()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            StillCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
