import StillCore
import SwiftUI

struct DeveloperView: View {
    @ObservedObject var model: AppModel
    let destination: SidebarDestination

    var body: some View {
        Group {
            switch destination {
            case .engines:
                List(model.installedEngines) { engine in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(engine.displayName).font(.headline)
                        Text("\(engine.id) · \(engine.version)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
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
    }
}
