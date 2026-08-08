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
                        Text(environment.ownership.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        Button("Restore Latest Restore Point…") {
                            Task { await model.prepareLatestRestorePoint(for: environment) }
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
                        if environment.ownership != .managed {
                            Divider()
                            Button("Adopt into Still…") {
                                model.requestEnvironmentAdoption(environment)
                            }
                            if environment.ownership != .externalReadOnly {
                                Button("Mark External, Read Only…") {
                                    model.requestExternalClassification(environment)
                                }
                            }
                        }
                        Divider()
                        Button("Remove from Still…", role: .destructive) {
                            model.requestEnvironmentRemoval(environment)
                        }
                        Button("Delete Environment…", role: .destructive) {
                            Task { await model.prepareDeletion(environment) }
                        }
                        .disabled(environment.ownership != .managed)
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
            Button("Restore Backup…", systemImage: "arrow.counterclockwise") {
                showsRestoreBackup = true
            }
                .help("Restore an Environment from a Still backup")
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
                    Button("Restore Latest Restore Point…") {
                        Task { await model.prepareLatestRestorePoint(for: environment) }
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
                    if environment.ownership != .managed {
                        Divider()
                        Button("Adopt into Still…") {
                            model.requestEnvironmentAdoption(environment)
                        }
                        if environment.ownership != .externalReadOnly {
                            Button("Mark External, Read Only…") {
                                model.requestExternalClassification(environment)
                            }
                        }
                    }
                    Divider()
                    Button("Remove from Still…", role: .destructive) {
                        model.requestEnvironmentRemoval(environment)
                    }
                    Button("Delete Environment…", role: .destructive) {
                        Task { await model.prepareDeletion(environment) }
                    }
                    .disabled(environment.ownership != .managed)
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
            "Adopt \(model.pendingEnvironmentAdoption?.name ?? "Environment") into Still?",
            isPresented: Binding(
                get: { model.pendingEnvironmentAdoption != nil },
                set: { if !$0 { model.pendingEnvironmentAdoption = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Copy and Adopt") {
                Task { await model.confirmEnvironmentAdoption() }
            }
            Button("Cancel", role: .cancel) { model.pendingEnvironmentAdoption = nil }
        } message: {
            Text("Still will copy the Environment into managed storage and update its Library entries. The source folder remains unchanged.")
        }
        .confirmationDialog(
            "Mark \(model.pendingExternalClassification?.name ?? "Environment") external?",
            isPresented: Binding(
                get: { model.pendingExternalClassification != nil },
                set: { if !$0 { model.pendingExternalClassification = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Mark External, Read Only") {
                Task { await model.confirmExternalClassification() }
            }
            Button("Cancel", role: .cancel) { model.pendingExternalClassification = nil }
        } message: {
            Text("Still will keep the registered path but will not treat its files as Still-managed data. Physical deletion remains unavailable.")
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
        .confirmationDialog(
            "Restore \(model.pendingRestorePointRestore?.environmentName ?? "Environment")?",
            isPresented: Binding(
                get: { model.pendingRestorePointRestore != nil },
                set: { if !$0 { model.pendingRestorePointRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                Task { await model.confirmRestorePoint() }
            }
            Button("Cancel", role: .cancel) { model.pendingRestorePointRestore = nil }
        } message: {
            if let point = model.pendingRestorePointRestore {
                Text("The current Environment files and Library configuration will be replaced with the Restore Point from \(point.createdAt.formatted(date: .abbreviated, time: .shortened)).")
            }
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
    @State private var manifest: BackupManifest?
    @State private var inspectionError: String?
    @State private var isInspecting = false

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
            if let manifest {
                Section("Restore Preview") {
                    LabeledContent("Environment", value: manifest.environment.name)
                    LabeledContent(
                        "Applications",
                        value: "\(manifest.snapshot.applications.count)"
                    )
                    LabeledContent("Files", value: "\(manifest.fileCount)")
                    LabeledContent(
                        "Data",
                        value: ByteCountFormatter.string(
                            fromByteCount: manifest.byteCount,
                            countStyle: .file
                        )
                    )
                    LabeledContent(
                        "Engine",
                        value: manifest.requiredEngineBuildID ?? "No pinned engine"
                    )
                    LabeledContent(
                        "Components",
                        value: "\(manifest.requiredComponents.count)"
                    )
                    ForEach(
                        manifest.snapshot.applications.sorted {
                            $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        }
                    ) { application in
                        Label(application.name, systemImage: application.category == .game
                            ? "gamecontroller"
                            : "app")
                    }
                    ForEach(manifest.requiredComponents.keys.sorted(), id: \.self) { id in
                        LabeledContent(id, value: manifest.requiredComponents[id] ?? "")
                    }
                    Text("Restore creates a new managed Environment and leaves existing Environments unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let inspectionError {
                Section {
                    Label(inspectionError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    if manifest == nil {
                        Button("Preview") {
                            Task { await inspectBackup() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(backupURL == nil || isInspecting)
                    } else {
                        Button("Restore") {
                            guard let backupURL else { return }
                            dismiss()
                            Task {
                                await model.restoreBackup(
                                    at: backupURL,
                                    password: password
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if isInspecting {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 580, maxWidth: 580, minHeight: 360, maxHeight: 680)
        .onChange(of: password) {
            manifest = nil
            inspectionError = nil
        }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Still Backup"
        panel.allowedContentTypes = [.data]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        backupURL = panel.url
        manifest = nil
        inspectionError = nil
    }

    private func inspectBackup() async {
        guard let backupURL else { return }
        isInspecting = true
        inspectionError = nil
        defer { isInspecting = false }
        do {
            manifest = try await model.inspectBackup(
                at: backupURL,
                password: password
            )
        } catch {
            manifest = nil
            inspectionError = error.localizedDescription
        }
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
    @State private var passwordConfirmation = ""

    var body: some View {
        Form {
            Section("Scope") {
                LabeledContent("Environment", value: environment.name)
                Text("Includes Environment files and a versioned runtime manifest. Engine binaries, account tokens, browser cookies, and Windows user documents are excluded.")
                    .foregroundStyle(.secondary)
            }
            Section("Protection") {
                Toggle("Encrypt with a password", isOn: $encrypted)
                if encrypted {
                    SecureField("Backup password", text: $password)
                    SecureField(
                        "Confirm backup password",
                        text: $passwordConfirmation
                    )
                    Text("This password cannot be recovered by Still.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !passwordConfirmation.isEmpty,
                       password != passwordConfirmation {
                        Text("The passwords do not match.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Section {
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Choose Destination…") { chooseDestination() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            encrypted
                                && (password.isEmpty || password != passwordConfirmation)
                        )
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 380)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Export Still Backup"
        panel.nameFieldStringValue = "\(environment.name).stillbackup"
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
