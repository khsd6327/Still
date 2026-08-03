import SwiftUI

struct StillCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("Application") {
            Button(primaryActionTitle) {
                Task { await model.performPrimaryApplicationAction() }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(primaryActionDisabled)

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
            .disabled(!model.hasLiveWineActivity)

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
            .disabled(!model.hasLiveWineActivity)
        }
    }

    private var primaryActionTitle: String {
        guard let application = model.selectedApplication else { return "Run" }
        return model.runtimeState(for: application).title
    }

    private var primaryActionDisabled: Bool {
        guard let application = model.selectedApplication else { return true }
        if [.launching, .stopping].contains(model.runtimeState(for: application)) { return true }
        return application.providerManagedState != nil
            && application.providerManagedState != .installed
            && model.runtimeState(for: application) == .idle
    }
}
