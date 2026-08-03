import StillCore
import SwiftUI

struct ApplicationInspector: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let application = model.selectedApplication {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ApplicationArtwork(
                            url: artworkURL(application),
                            fallbackSystemImage: application.category == .game
                                ? "gamecontroller.fill"
                                : "app.fill",
                            inset: 8
                        )
                            .frame(width: 44, height: 44)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading) {
                            Text(application.name).font(.headline)
                            Text(application.category.rawValue.capitalized)
                                .foregroundStyle(.secondary)
                        }
                    }
                    let runtimeState = model.runtimeState(for: application)
                    Button(runtimeState.title, systemImage: runtimeState.systemImage) {
                        Task { await model.performPrimaryApplicationAction(applicationID: application.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        runtimeState == .launching || runtimeState == .stopping
                            || (runtimeState == .idle
                                && application.providerManagedState != nil
                                && application.providerManagedState != .installed)
                    )
                    if runtimeState == .running {
                        Button("Request Stop", systemImage: "stop.fill") {
                            Task { await model.stopApplicationNormally(applicationID: application.id) }
                        }
                        Button("Force Stop", systemImage: "exclamationmark.octagon", role: .destructive) {
                            model.requestForceStop(applicationID: application.id)
                        }
                    }
                    Button(
                        application.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: application.isFavorite ? "star.slash" : "star"
                    ) {
                        Task { await model.toggleFavorite(application) }
                    }
                }
                Section("Status") {
                    LabeledContent("Environment", value: environmentName(application))
                    LabeledContent("Last Used", value: application.lastLaunchedAt?.formatted() ?? "Never")
                    LabeledContent(
                        "Compatibility",
                        value: model.effectiveProfileID(for: application) ?? "Environment Default"
                    )
                    if let provider = application.providerID {
                        LabeledContent("Provider", value: provider.capitalized)
                    }
                    if let state = application.providerManagedState {
                        LabeledContent("Provider status", value: providerStateLabel(state))
                    }
                }
                Section("Files") {
                    if let entry = primaryEntry(application) {
                        Text(displayPath(entry.executableURL, for: application))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                        Button("Reveal in Finder", systemImage: "folder") {
                            model.revealSelectedApplication()
                        }
                    } else {
                        Text("Launch file is missing.").foregroundStyle(.secondary)
                    }
                }
                Section("Recent Failures") {
                    let failures = model.recentFailures(for: application)
                    if failures.isEmpty {
                        Text("No recorded failures.").foregroundStyle(.secondary)
                    } else {
                        ForEach(failures.prefix(3)) { failure in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(failure.resultSummary ?? "Launch failed")
                                Text(failure.createdAt, style: .relative)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Inspector")
        } else {
            ContentUnavailableView(
                "No Application Selected",
                systemImage: "cursorarrow.click"
            )
        }
    }

    private func environmentName(_ application: LibraryApplication) -> String {
        model.environments.first(where: { $0.id == application.environmentID })?.name ?? "Missing"
    }

    private func primaryEntry(_ application: LibraryApplication) -> LaunchEntry? {
        guard let id = application.launchEntryIDs.first else { return nil }
        return model.launchEntries.first { $0.id == id }
    }

    private func artworkURL(_ application: LibraryApplication) -> URL? {
        guard let entry = primaryEntry(application) else { return nil }
        return ApplicationArtworkResolver.resolve(
            application: application,
            launcherURL: entry.executableURL
        )
    }

    private func providerStateLabel(_ state: WindowsApplicationInstallState) -> String {
        switch state {
        case .installed: "Installed"
        case .downloading: "Downloading"
        case .needsUpdate: "Update Required"
        case .unknown: "Unknown"
        }
    }

    private func displayPath(_ executableURL: URL, for application: LibraryApplication) -> String {
        guard let environment = model.environments.first(where: { $0.id == application.environmentID }) else {
            return executableURL.lastPathComponent
        }

        let driveRoot = environment.prefixURL.appending(path: "drive_c").standardizedFileURL.path
        let executablePath = executableURL.standardizedFileURL.path
        guard executablePath.hasPrefix(driveRoot + "/") else {
            return executableURL.lastPathComponent
        }

        let relativePath = executablePath.dropFirst(driveRoot.count + 1)
        return "C:\\" + relativePath.replacingOccurrences(of: "/", with: "\\")
    }
}
