import SwiftUI

struct FeatureStateView: View {
    let state: FeatureLoadState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView("Working")
                .controlSize(.small)
                .accessibilityLabel("Operation in progress")
        case .success(let message):
            if let message {
                Label(message, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        case .partial(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
        case .offline(let message):
            Label(message, systemImage: "network.slash")
                .foregroundStyle(.secondary)
        case .recovery(let message):
            Label(message, systemImage: "arrow.counterclockwise.circle")
                .foregroundStyle(.orange)
        }
    }
}
