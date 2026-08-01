import SwiftUI

struct StillCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("Application") {
            Button("Run") {
                Task { await model.launchSelectedApplication() }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(model.selectedApplication == nil || model.selectedSession != nil)

            Button("Reveal in Finder") {
                model.revealSelectedApplication()
            }
            .disabled(model.selectedApplication == nil)

            Divider()

            Button("Scan Environments") {
                Task { await model.scanApplications() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.environments.isEmpty)
        }

        CommandMenu("Process") {
            Button("Request Stop") {
                Task { await model.stopSelectedNormally() }
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
            .disabled(model.selectedSession == nil)

            Button("Request Stop All") {
                Task { await model.stopAllNormally() }
            }
            .keyboardShortcut("k", modifiers: [.command, .option, .shift])
            .disabled(model.sessions.isEmpty)

            Divider()

            Button("Force Stop") {
                model.requestForceStopSelected()
            }
            .keyboardShortcut("k", modifiers: [.command, .option, .control])
            .disabled(model.selectedSession == nil)

            Button("Force Stop All") {
                model.requestForceStopAll()
            }
            .keyboardShortcut("k", modifiers: [.command, .option, .control, .shift])
            .disabled(model.sessions.isEmpty)
        }
    }
}
