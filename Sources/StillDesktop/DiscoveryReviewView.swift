import StillCore
import SwiftUI

struct DiscoveryReviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            List(model.pendingDiscoveryCandidates) { pending in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pending.candidate.application.name)
                                .font(.headline)
                            Text(environmentName(pending.environmentID))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(confidenceLabel(pending.candidate.confidence))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }

                    Text(pending.candidate.application.launcherURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    HStack {
                        Button("Add to Library") {
                            Task { await model.confirmDiscovery(pending) }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Ignore") { model.ignoreDiscovery(pending) }
                    }
                }
                .padding(.vertical, 6)
            }
            .navigationTitle("Review Discovered Applications")
            .frame(minWidth: 560, minHeight: 360)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.pendingDiscoveryCandidates.removeAll() }
                }
            }
        }
    }

    private func environmentName(_ id: WindowsEnvironment.ID) -> String {
        model.environments.first(where: { $0.id == id })?.name ?? "Unknown Environment"
    }

    private func confidenceLabel(_ confidence: DiscoveryConfidence) -> String {
        switch confidence.rawValue {
        case 0.85...: "High confidence"
        case 0.65...: "Medium confidence"
        default: "Low confidence"
        }
    }
}
