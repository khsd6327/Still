import AppKit
import StillCore
import SwiftUI

struct EnvironmentsView: View {
    @ObservedObject var model: AppModel
    @State private var backupEnvironment: WindowsEnvironment?
    @State private var showsRestoreBackup = false

    var body: some View {
        Group {
            if model.environments.isEmpty {
                ContentUnavailableView {
                    Label("No Environments", systemImage: "shippingbox")
                } description: {
                    Text("Create one for a new installation or import an existing Wine prefix.")
                } actions: {
                    Button("Create Environment") { Task { await model.createEnvironment() } }
                    Button("Import…") { Task { await model.importEnvironment() } }
                }
            } else {
                List(model.environments, selection: $model.selectedEnvironmentID) { environment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(environment.name).font(.headline)
                        Text(environment.prefixURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(environment.id)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(environment.name)
                    .accessibilityValue("Environment, \(applicationCount(environment)) applications")
                    .accessibilityHint("Selects this Environment. Additional actions are available from the context menu.")
                    .contextMenu {
                        Button("Scan Applications") {
                            Task { await model.scanApplications(environmentID: environment.id) }
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([environment.prefixURL])
                        }
                        Divider()
                        Button("Create Restore Point") {
                            Task { await model.createRestorePoint(for: environment) }
                        }
                        Button("Duplicate Environment") {
                            Task { await model.duplicate(environment) }
                        }
                        Button("Inspect and Repair…") {
                            Task { await model.inspectRepair(environment) }
                        }
                        Button("Export Partial Data…") {
                            backupEnvironment = environment
                        }
                        Divider()
                        Button("Remove from Still…", role: .destructive) {
                            model.requestEnvironmentRemoval(environment)
                        }
                    }
                }
            }
        }
        .navigationTitle("Environments")
        .toolbar {
            Button("Scan", systemImage: "arrow.clockwise") {
                Task { await model.scanApplications(environmentID: model.selectedEnvironmentID) }
            }
            .disabled(model.environments.isEmpty)
            Button("Import", systemImage: "square.and.arrow.down") {
                Task { await model.importEnvironment() }
            }
            Button("Restore Unavailable", systemImage: "arrow.counterclockwise") {}
                .disabled(true)
                .help("Restore is temporarily unavailable while transactional rollback is being implemented.")
            Button("Create", systemImage: "plus") {
                Task { await model.createEnvironment() }
            }
            Menu("Environment Actions", systemImage: "ellipsis.circle") {
                if let environment = model.selectedEnvironment {
                    Button("Scan Applications") {
                        Task { await model.scanApplications(environmentID: environment.id) }
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([environment.prefixURL])
                    }
                    Divider()
                    Button("Create Restore Point") {
                        Task { await model.createRestorePoint(for: environment) }
                    }
                    Button("Duplicate Environment") {
                        Task { await model.duplicate(environment) }
                    }
                    Button("Inspect and Repair…") {
                        Task { await model.inspectRepair(environment) }
                    }
                    Button("Export Partial Data…") {
                        backupEnvironment = environment
                    }
                    Divider()
                    Button("Remove from Still…", role: .destructive) {
                        model.requestEnvironmentRemoval(environment)
                    }
                }
            }
            .disabled(model.selectedEnvironment == nil)
            .accessibilityHint("Contains backup, repair, duplication, and deletion actions for the selected Environment")
        }
        .sheet(item: $backupEnvironment) { environment in
            BackupExportView(model: model, environment: environment)
        }
        .sheet(isPresented: $showsRestoreBackup) {
            BackupRestoreView(model: model)
        }
        .sheet(item: $model.repairReport) { report in
            RepairReportView(report: report) {
                model.repairReport = nil
            }
        }
        .sheet(item: $model.deletionPreview) { preview in
            DeletionPreviewView(model: model, preview: preview)
        }
        .confirmationDialog(
            "Remove \(model.pendingEnvironmentRemoval?.name ?? "Environment") from Still?",
            isPresented: Binding(
                get: { model.pendingEnvironmentRemoval != nil },
                set: { if !$0 { model.pendingEnvironmentRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from Still", role: .destructive) {
                Task { await model.confirmEnvironmentRemoval() }
            }
            Button("Cancel", role: .cancel) { model.pendingEnvironmentRemoval = nil }
        } message: {
            Text("Still will remove this Environment and its Library entries. Files at the registered path will remain unchanged.")
        }
        .alert(
            "Permanently delete \(model.deletionPreview?.environmentName ?? "Environment")?",
            isPresented: $model.requiresPermanentDeletionConfirmation
        ) {
            Button("Delete Permanently", role: .destructive) {
                Task { await model.confirmPermanentDeletion() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let preview = model.deletionPreview {
                Text("This permanently removes \(preview.environmentName), its folder, and \(preview.affectedApplications.count) Library applications. Estimated size: \(ByteCountFormatter.string(fromByteCount: preview.estimatedByteCount, countStyle: .file)). This cannot be undone.")
            }
        }
        .alert(
            "Restore Point Created",
            isPresented: Binding(
                get: { model.latestRestorePoint != nil },
                set: { if !$0 { model.latestRestorePoint = nil } }
            )
        ) {
            Button("OK") { model.latestRestorePoint = nil }
        } message: {
            if let point = model.latestRestorePoint {
                Text("\(point.fileCount) files, \(ByteCountFormatter.string(fromByteCount: point.byteCount, countStyle: .file)).")
            }
        }
    }

    private func applicationCount(_ environment: WindowsEnvironment) -> Int {
        model.applications.filter { $0.environmentID == environment.id }.count
    }
}

private struct BackupRestoreView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var backupURL: URL?
    @State private var password = ""

    var body: some View {
        Form {
            Section("Backup") {
                LabeledContent("File", value: backupURL?.lastPathComponent ?? "Not selected")
                Button("Choose Still Backup…") { chooseBackup() }
            }
            Section("Password") {
                SecureField("Leave blank for an unencrypted backup", text: $password)
                Text("Encrypted backups cannot be inspected or restored without the correct password.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Preview and Restore") {
                        guard let backupURL else { return }
                        dismiss()
                        Task { await model.restoreBackup(at: backupURL, password: password) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(backupURL == nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 330)
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Still Backup"
        panel.allowedContentTypes = [.data]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        backupURL = panel.url
    }
}

private struct RepairReportView: View {
    let report: RepairReport
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if report.isHealthy {
                    ContentUnavailableView("Environment is Healthy", systemImage: "checkmark.circle")
                } else {
                    List(report.issues) { issue in
                        Label {
                            VStack(alignment: .leading) {
                                Text(issue.summary)
                                Text(issue.severity.rawValue.capitalized)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: issue.severity == .blocking ? "xmark.octagon" : "exclamationmark.triangle")
                        }
                    }
                }
            }
            .navigationTitle("Repair Inspection")
            .toolbar { Button("Done", action: dismiss) }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}

private struct BackupExportView: View {
    @ObservedObject var model: AppModel
    let environment: WindowsEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var encrypted = false
    @State private var password = ""

    var body: some View {
        Form {
            Section("Scope") {
                LabeledContent("Environment", value: environment.name)
                Text("Includes Environment files and a versioned runtime manifest. Engine binaries, account tokens, browser cookies, and Windows user documents are excluded.")
                    .foregroundStyle(.secondary)
            }
            Section("Protection") {
                Toggle("Encrypt with a password", isOn: $encrypted)
                    .disabled(true)
                if encrypted {
                    SecureField("Backup password", text: $password)
                    Text("This password cannot be recovered by Still.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Password protection is temporarily unavailable while its key derivation is being upgraded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Choose Destination…") { chooseDestination() }
                        .buttonStyle(.borderedProminent)
                        .disabled(encrypted && password.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 380)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Export Experimental Partial Data"
        panel.nameFieldStringValue = "\(environment.name).stillpartial"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dismiss()
        Task {
            await model.exportBackup(
                environment: environment,
                destinationURL: url,
                encrypted: encrypted,
                password: encrypted ? password : nil
            )
        }
    }
}

private struct DeletionPreviewView: View {
    @ObservedObject var model: AppModel
    let preview: EnvironmentDeletionPreview

    var body: some View {
        Form {
            Section("Environment") {
                LabeledContent("Name", value: preview.environmentName)
                LabeledContent("Applications", value: "\(preview.affectedApplications.count)")
                LabeledContent(
                    "Estimated size",
                    value: ByteCountFormatter.string(
                        fromByteCount: preview.estimatedByteCount,
                        countStyle: .file
                    )
                )
                Text(preview.prefixURL.path)
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Deletion scope for \(preview.environmentName), \(preview.affectedApplications.count) applications, \(preview.estimatedByteCount) bytes")
            Section("Deletion Method") {
                Picker("Method", selection: $model.selectedDeletionMethod) {
                    Text("Move to Trash").tag(EnvironmentDeletionMethod.moveToTrash)
                    Text("Delete Permanently").tag(EnvironmentDeletionMethod.permanentlyDelete)
                }
                Toggle("Remember this method", isOn: $model.rememberDeletionMethod)
                Toggle("Do not show this explanation again", isOn: $model.suppressDeletionExplanation)
                if model.selectedDeletionMethod == .permanentlyDelete {
                    Label("A final permanent-deletion confirmation is always required.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section {
                HStack {
                    Button("Cancel") { model.deletionPreview = nil }
                    Spacer()
                    Button("Continue", role: model.selectedDeletionMethod == .permanentlyDelete ? .destructive : nil) {
                        Task { await model.continueDeletion() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 470)
    }
}
