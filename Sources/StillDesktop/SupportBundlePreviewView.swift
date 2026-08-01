import AppKit
import StillCore
import SwiftUI

struct SupportBundlePreviewView: View {
    @ObservedObject var model: AppModel
    let draft: SupportBundleDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Only the files listed below will be exported. Credentials, personal paths, process identifiers, Environment files, and engine binaries are excluded or redacted.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .accessibilityLabel("Privacy scope")
                    .accessibilityValue("Credentials, personal paths, process identifiers, Environment files, and engine binaries are excluded or redacted")

                List(draft.previewEntries) { entry in
                    LabeledContent {
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(entry.byteCount),
                            countStyle: .file
                        ))
                        .monospacedDigit()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.relativePath).font(.body.monospaced())
                            Text(entry.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(entry.relativePath)
                    .accessibilityValue("\(entry.summary), \(entry.byteCount) bytes")
                }
            }
            .navigationTitle("Support Bundle Preview")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("\(draft.files.count) files, \(ByteCountFormatter.string(fromByteCount: Int64(draft.totalByteCount), countStyle: .file))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Export…") { chooseDestination() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
                .background(.bar)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Export Support Bundle"
        panel.nameFieldStringValue = "Still Support.stillsupport"
        panel.message = "Still will create a local folder containing exactly the previewed files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dismiss()
        model.exportSupportBundle(draft, to: url)
    }
}
