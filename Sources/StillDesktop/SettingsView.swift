import AppKit
import StillCore
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case library
    case installation
    case engines
    case compatibility
    case storageRecovery
    case developer
    case diagnostics

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .library: "Library"
        case .installation: "Installation"
        case .engines: "Engines"
        case .compatibility: "Compatibility"
        case .storageRecovery: "Storage & Recovery"
        case .developer: "Developer"
        case .diagnostics: "Diagnostics"
        }
    }
    var icon: String {
        switch self {
        case .general: "gear"
        case .library: "square.grid.2x2"
        case .installation: "plus.app"
        case .engines: "cpu"
        case .compatibility: "slider.horizontal.3"
        case .storageRecovery: "externaldrive"
        case .developer: "hammer"
        case .diagnostics: "stethoscope"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Form {
                switch selection ?? .general {
                case .general: general
                case .library: library
                case .installation: installation
                case .engines: engines
                case .compatibility: compatibility
                case .storageRecovery: storageRecovery
                case .developer: developer
                case .diagnostics: diagnostics
                }
            }
            .formStyle(.grouped)
            .navigationTitle((selection ?? .general).title)
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 480, idealHeight: 520)
        .alert("Developer Mode", isPresented: $model.showsDeveloperModeExplanation) {
            Button("Continue") {
                UserDefaults.standard.set(true, forKey: "developerModeExplanationDismissed")
            }
        } message: {
            Text("Developer Mode reveals technical information and controls. Enabling it does not change compatibility settings.")
        }
        .confirmationDialog(
            "Custom compatibility settings are active.",
            isPresented: $model.showsDeveloperDisableAudit
        ) {
            Button("Keep Custom Settings") {
                Task { await model.disableDeveloperModeKeepingOverrides(true) }
            }
            Button("Reset Custom Settings", role: .destructive) {
                Task { await model.disableDeveloperModeKeepingOverrides(false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose whether to keep or reset expert overrides before hiding Developer Mode.")
        }
        .sheet(item: $model.pendingEngineLicenseManifest) { manifest in
            EngineLicenseView(model: model, manifest: manifest)
        }
        .sheet(item: $model.supportBundleDraft) { draft in
            SupportBundlePreviewView(model: model, draft: draft)
        }
        .alert(
            "Support Bundle Exported",
            isPresented: Binding(
                get: { model.supportBundleExportedURL != nil },
                set: { if !$0 { model.supportBundleExportedURL = nil } }
            )
        ) {
            Button("Show in Finder") {
                if let url = model.supportBundleExportedURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                model.supportBundleExportedURL = nil
            }
            Button("OK") { model.supportBundleExportedURL = nil }
        } message: {
            Text("The previewed, sanitized files were exported locally.")
        }
    }

    private var general: some View {
        Section("Quitting Still") {
            Picker("When applications are running", selection: $model.closeRunningBehavior) {
                ForEach(CloseRunningBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            Text("This setting applies to both the main window's close button and Quit Still.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var library: some View {
        Section("Appearance") {
            Picker("Default view", selection: $model.presentation) {
                Text("Grid").tag(LibraryPresentation.grid)
                Text("List").tag(LibraryPresentation.list)
            }
            Toggle("Show Inspector", isOn: $model.inspectorPresented)
        }
    }

    private var installation: some View {
        Section {
            Text("Windows installers are selected from local EXE or MSI files.")
            Text("New applications use a dedicated Environment unless a validated Profile permits sharing.")
        }
    }

    private var engines: some View {
        Group {
            Section("Installed") {
                if model.installedEngines.isEmpty {
                    Text("No engines installed.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.installedEngines) { engine in
                        LabeledContent(engine.displayName, value: engine.version)
                    }
                }
            }
            Section("Available") {
                if model.availableEngineManifests.isEmpty {
                    Text("All catalog engines are installed.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.availableEngineManifests) { manifest in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(manifest.displayName).font(.headline)
                                    Text(ByteCountFormatter.string(
                                        fromByteCount: manifest.downloadSize,
                                        countStyle: .file
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(
                                    model.installingEngineID == manifest.id
                                        ? "Installing…"
                                        : "Install"
                                ) {
                                    model.requestEngineInstallation(manifest)
                                }
                                .disabled(model.installingEngineID != nil)
                            }
                            ForEach(manifest.requirements, id: \.self) { requirement in
                                Label(requirement, systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if manifest.distributionPolicy == .externalLicenseRequired {
                                Label("Requires separate license review", systemImage: "doc.text")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section {
                FeatureStateView(state: model.engineInstallationState)
            }
        }
    }

    private var compatibility: some View {
        Section {
            Text("Still uses validated Profile recommendations and Environment defaults.")
            Text("Unavailable graphics and synchronization choices remain excluded.")
                .foregroundStyle(.secondary)
        }
    }

    private var storageRecovery: some View {
        Group {
            Section("Data") {
                LabeledContent("Location") {
                    Text(JSONBottleStore.defaultRootURL().path)
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Environment deletion", value: "Managed Environments only")
                Text("Environments can be removed from Still without changing their files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Logs") {
                Stepper(
                    "Keep logs for \(model.logRetentionDays) days",
                    value: $model.logRetentionDays,
                    in: 1...90
                )
            }
        }
    }

    private var developer: some View {
        Section {
            Toggle(
                "Developer Mode",
                isOn: Binding(
                    get: { model.developerModeEnabled },
                    set: { enabled in model.setDeveloperMode(enabled) }
                )
            )
            Text("Reveals engines, process inspection, diagnostics, and expert compatibility details. It changes no setting by itself.")
                .font(.caption).foregroundStyle(.secondary)
            if model.hasCustomCompatibility {
                Label("Custom Compatibility is active", systemImage: "slider.horizontal.3")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var diagnostics: some View {
        Section("Support Bundle") {
            Text("Preview a package containing configuration, engine metadata, operation history, and recent launch logs.")
                .foregroundStyle(.secondary)
            Button("Preview Support Bundle…", systemImage: "doc.text.magnifyingglass") {
                Task { await model.prepareSupportBundle() }
            }
            .accessibilityHint("Shows every file and size before export")
        }
    }
}

private struct EngineLicenseView: View {
    @ObservedObject var model: AppModel
    let manifest: EngineManifest
    @Environment(\.dismiss) private var dismiss
    @State private var accepted = false

    var body: some View {
        Form {
            Section("Engine") {
                LabeledContent("Name", value: manifest.displayName)
                LabeledContent("Version", value: manifest.version)
                LabeledContent(
                    "Download",
                    value: ByteCountFormatter.string(
                        fromByteCount: manifest.downloadSize,
                        countStyle: .file
                    )
                )
            }
            Section("License") {
                if let licenseURL = manifest.licenseURL {
                    Link("Review License and Source", destination: licenseURL)
                }
                Toggle("I reviewed and accept the engine license", isOn: $accepted)
                Text("Acceptance is recorded locally for this engine version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Cancel") {
                        model.cancelLicensedEngineInstallation()
                        dismiss()
                    }
                    Spacer()
                    Button("Accept and Install") {
                        model.confirmLicensedEngineInstallation()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!accepted)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 390)
        .interactiveDismissDisabled()
    }
}
