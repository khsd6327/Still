import StillCore
import SwiftUI

private struct PendingEngineChange: Identifiable {
    let environment: WindowsEnvironment
    let engine: EngineDescriptor

    var id: String { "\(environment.id.uuidString):\(engine.id)" }
}

struct DeveloperView: View {
    @ObservedObject var model: AppModel
    let destination: SidebarDestination
    @State private var pendingEngineChange: PendingEngineChange?

    var body: some View {
        Group {
            switch destination {
            case .engines:
                List(model.installedEngines) { engine in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(engine.displayName).font(.headline)
                                if model.selectedEnvironment?.pinnedEngineBuildID == engine.id {
                                    Text("IN USE")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text("\(engine.id) · \(engine.version)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let environment = model.selectedEnvironment,
                           environment.pinnedEngineBuildID != engine.id {
                            Button("Use for \(environment.name)") {
                                pendingEngineChange = PendingEngineChange(
                                    environment: environment,
                                    engine: engine
                                )
                            }
                            .disabled(hasActiveSession(in: environment))
                        }
                    }
                }
            case .processInspector:
                if model.sessions.isEmpty {
                    ContentUnavailableView("No Active Sessions", systemImage: "list.bullet.rectangle")
                } else {
                    List(model.sessions) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.id.uuidString).font(.caption.monospaced())
                            Text("PID \(session.processIdentifier) · \(session.state.rawValue)")
                            if let logURL = session.logURL {
                                Text(logURL.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            case .diagnostics:
                Form {
                    Section("Runtime") {
                        LabeledContent("Environments", value: "\(model.environments.count)")
                        LabeledContent("Applications", value: "\(model.applications.count)")
                        LabeledContent("Active sessions", value: "\(model.sessions.count)")
                    }
                    Section("Bridge") {
                        Text("Bridge diagnostics appear when a compatible engine exposes them.")
                            .foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            case .labs:
#if DEBUG
                ContentUnavailableView(
                    "Labs",
                    systemImage: "flask",
                    description: Text("Development-only experiments appear here. No experiments are enabled.")
                )
#else
                ContentUnavailableView("Unavailable", systemImage: "lock")
#endif
            default:
                EmptyView()
            }
        }
        .navigationTitle(destination.title)
        .confirmationDialog(
            engineChangeTitle,
            isPresented: Binding(
                get: { pendingEngineChange != nil },
                set: { if !$0 { pendingEngineChange = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let change = pendingEngineChange {
                Button("Create Restore Point and Change Engine") {
                    pendingEngineChange = nil
                    Task {
                        await model.changePinnedEngine(
                            for: change.environment,
                            to: change.engine
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingEngineChange = nil }
        } message: {
            Text("Still will preserve the current Environment before changing its engine. Running applications must be stopped first.")
        }
    }

    private var engineChangeTitle: String {
        guard let change = pendingEngineChange else { return "Change Engine?" }
        return "Use \(change.engine.displayName) for \(change.environment.name)?"
    }

    private func hasActiveSession(in environment: WindowsEnvironment) -> Bool {
        model.sessions.contains { session in
            session.environmentID == environment.id && session.state.isActive
        }
    }
}
