import AppKit
import SwiftUI

@MainActor
final class StillApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.sessions.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Windows applications are still running."
        alert.informativeText = "Choose whether to leave them running, stop them normally, or cancel quitting Still."
        alert.addButton(withTitle: "Leave Running and Quit")
        alert.addButton(withTitle: "Stop Normally and Quit")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .terminateNow
        case .alertSecondButtonReturn:
            Task {
                await model.stopAllNormally()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        default:
            return .terminateCancel
        }
    }
}

struct WindowCloseGuard: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var model: AppModel?
        private weak var attachedWindow: NSWindow?
        private var bypassNextClose = false

        init(model: AppModel) {
            self.model = model
        }

        func attach(to window: NSWindow?) {
            guard let window, attachedWindow !== window else { return }
            attachedWindow = window
            window.setFrameAutosaveName("Still.MainWindow")
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !bypassNextClose,
                  let model,
                  !model.sessions.isEmpty else {
                bypassNextClose = false
                return true
            }

            switch model.closeRunningBehavior {
            case .leaveRunning:
                return true
            case .stopAndClose:
                stopThenClose(sender, model: model)
                return false
            case .ask:
                return presentCloseChoice(sender, model: model)
            }
        }

        private func presentCloseChoice(_ window: NSWindow, model: AppModel) -> Bool {
            let alert = NSAlert()
            alert.messageText = "Windows applications are still running."
            alert.informativeText = "Stop them normally before closing the window?"
            alert.addButton(withTitle: "Stop Normally and Close")
            alert.addButton(withTitle: "Leave Running")
            alert.addButton(withTitle: "Cancel")
            let remember = NSButton(checkboxWithTitle: "Remember This Choice", target: nil, action: nil)
            alert.accessoryView = remember

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if remember.state == .on { model.closeRunningBehavior = .stopAndClose }
                stopThenClose(window, model: model)
                return false
            case .alertSecondButtonReturn:
                if remember.state == .on { model.closeRunningBehavior = .leaveRunning }
                return true
            default:
                return false
            }
        }

        private func stopThenClose(_ window: NSWindow, model: AppModel) {
            Task {
                await model.stopAllNormally()
                bypassNextClose = true
                window.performClose(nil)
            }
        }
    }
}
