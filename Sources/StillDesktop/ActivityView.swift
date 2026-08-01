import StillCore
import SwiftUI

struct ActivityView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.operations.isEmpty && model.sessions.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "waveform.path.ecg",
                    description: Text("Install, launch, repair, and backup activity appears here.")
                )
            } else {
                List {
                    if !model.sessions.isEmpty {
                        Section("Running") {
                            ForEach(model.sessions) { session in
                                HStack {
                                    Image(systemName: "play.circle.fill").foregroundStyle(.green)
                                    VStack(alignment: .leading) {
                                        Text(applicationName(session.applicationID))
                                        Text(session.state.rawValue.capitalized)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(session.startedAt, style: .relative)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(applicationName(session.applicationID))
                                .accessibilityValue("Running, \(session.state.rawValue), started \(session.startedAt.formatted(.relative(presentation: .named)))")
                            }
                        }
                    }
                    if !model.operations.isEmpty {
                        Section("Recent Operations") {
                            ForEach(model.operations) { operation in
                                HStack {
                                    Image(systemName: icon(operation.state))
                                        .foregroundStyle(color(operation.state))
                                    VStack(alignment: .leading) {
                                        Text(operation.kind.rawValue.spacedTitle)
                                        Text(operation.resultSummary ?? operation.state.rawValue.capitalized)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(operation.createdAt, style: .relative)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(operation.kind.rawValue.spacedTitle)
                                .accessibilityValue(operationAccessibilityValue(operation))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refreshActivity() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            FeatureStateView(state: model.activityState).font(.caption).padding(8)
        }
    }

    private func applicationName(_ id: LibraryApplication.ID?) -> String {
        guard let id else { return "Windows Process" }
        return model.applications.first(where: { $0.id == id })?.name ?? "Unknown Application"
    }

    private func icon(_ state: OperationState) -> String {
        switch state {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "slash.circle"
        default: "arrow.triangle.2.circlepath.circle"
        }
    }

    private func color(_ state: OperationState) -> Color {
        switch state {
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        default: .accentColor
        }
    }

    private func operationAccessibilityValue(_ operation: StillOperation) -> String {
        let result = operation.resultSummary ?? operation.state.rawValue.capitalized
        return "\(operation.state.rawValue), \(result), created \(operation.createdAt.formatted(.relative(presentation: .named)))"
    }
}

private extension String {
    var spacedTitle: String {
        unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar), !result.isEmpty { result.append(" ") }
            result.append(Character(scalar))
        }.capitalized
    }
}
