import AppKit
import SwiftUI

enum ApplicationTerminationAction: Equatable {
    case terminateNow
    case requestNormalStop
    case ask
}

enum ApplicationTerminationPolicy {
    static func action(
        hasLiveWineActivity: Bool,
        closeRunningBehavior: CloseRunningBehavior
    ) -> ApplicationTerminationAction {
        guard hasLiveWineActivity else { return .terminateNow }

        switch closeRunningBehavior {
        case .ask:
            return .ask
        case .stopAndClose:
            return .requestNormalStop
        case .leaveRunning:
            return .terminateNow
        }
    }
}

@MainActor
final class StillApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isStoppingBeforeTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }

        switch ApplicationTerminationPolicy.action(
            hasLiveWineActivity: model.hasLiveWineActivity,
            closeRunningBehavior: model.closeRunningBehavior
        ) {
        case .terminateNow:
            return .terminateNow
        case .requestNormalStop:
            return requestNormalStopBeforeTermination(sender, model: model)
        case .ask:
            return presentTerminationChoice(sender, model: model)
        }
    }

    private func presentTerminationChoice(
        _ sender: NSApplication,
        model: AppModel
    ) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "Windows applications are still running."
        alert.informativeText = "Choose whether to leave them running, stop them normally, or cancel quitting Still."
        alert.addButton(withTitle: "Request Stop and Quit")
        alert.addButton(withTitle: "Leave Running and Quit")
        alert.addButton(withTitle: "Cancel")
        let remember = NSButton(
            checkboxWithTitle: "Remember This Choice",
            target: nil,
            action: nil
        )
        alert.accessoryView = remember

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if remember.state == .on {
                model.closeRunningBehavior = .stopAndClose
            }
            return requestNormalStopBeforeTermination(sender, model: model)
        case .alertSecondButtonReturn:
            if remember.state == .on {
                model.closeRunningBehavior = .leaveRunning
            }
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    private func requestNormalStopBeforeTermination(
        _ sender: NSApplication,
        model: AppModel
    ) -> NSApplication.TerminateReply {
        guard !isStoppingBeforeTermination else { return .terminateLater }
        isStoppingBeforeTermination = true
        Task { [weak self] in
            let stopped = await model.stopAllNormally()
            self?.isStoppingBeforeTermination = false
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }
}

struct WindowCloseGuard: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
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
        private let requestApplicationTermination: @MainActor () -> Void
        private weak var attachedWindow: NSWindow?

        init(requestApplicationTermination: @escaping @MainActor () -> Void = {
            NSApplication.shared.terminate(nil)
        }) {
            self.requestApplicationTermination = requestApplicationTermination
        }

        func attach(to window: NSWindow?) {
            guard let window, attachedWindow !== window else { return }
            attachedWindow = window
            window.setFrameAutosaveName("Still.MainWindow")
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            requestApplicationTermination()
            return false
        }
    }
}
