import SwiftUI

struct InstallView: View {
    @ObservedObject var model: AppModel
    @State private var newEnvironmentName = ""

    var body: some View {
        Form {
            Section("Installer") {
                LabeledContent("Local file") {
                    Text(model.installDraft.installerURL?.lastPathComponent ?? "Not selected")
                        .foregroundStyle(model.installDraft.installerURL == nil ? .secondary : .primary)
                }
                Button("Choose EXE or MSI…", systemImage: "doc.badge.plus") {
                    model.chooseLocalInstaller()
                }
                Text("Still uses only the file you choose. It does not download Windows applications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let profile = model.matchedInstallerProfile {
                    LabeledContent("Recognized profile", value: profile.displayName)
                    Text("The selected installer remains user supplied. Still applies only the bundled compatibility defaults and installer arguments.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Environment") {
                if model.environments.isEmpty {
                    ContentUnavailableView(
                        "No Environments",
                        systemImage: "shippingbox",
                        description: Text("Create or import an Environment first.")
                    )
                } else {
                    Picker("Install into", selection: $model.installDraft.environmentID) {
                        Text("Choose an Environment").tag(Optional<UUID>.none)
                        ForEach(model.environments) { environment in
                            Text(environment.name).tag(Optional(environment.id))
                        }
                    }
                }
                HStack {
                    TextField("New Environment name", text: $newEnvironmentName)
                    Button("Create") {
                        let name = newEnvironmentName
                        newEnvironmentName = ""
                        Task { await model.createEnvironment(name: name) }
                    }
                }
                Button("Import Existing Environment…", systemImage: "square.and.arrow.down") {
                    Task { await model.importEnvironment() }
                }
            }

            Section {
                Button("Run Installer", systemImage: "play.fill") {
                    Task { await model.runSelectedInstaller() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.installDraft.installerURL == nil
                        || model.installDraft.environmentID == nil
                        || model.installState == .loading
                )
            } footer: {
                FeatureStateView(state: model.installState)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Install")
    }
}
