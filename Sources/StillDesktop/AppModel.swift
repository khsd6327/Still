import AppKit
import Foundation
import Metal
import StillCore
import UniformTypeIdentifiers

private enum StabilizationGate {
    static let physicalEnvironmentDeletionEnabled = true
}

@MainActor
final class AppModel: ObservableObject {
    private let store = JSONStillStore()
    private let legacyBottleStore = JSONBottleStore()
    private let engineInstaller = EngineInstaller()
    private let discoveryCoordinator = ApplicationDiscoveryCoordinator()
    private let supervisor = ProcessSupervisor()
    private let restorePointService = RestorePointService()
    private let backupService = BackupService()
    private let recoveryService = EnvironmentRecoveryService()
    private let repairService = RepairService()
    private let logRotationService = LogRotationService()
    private let supportBundleService = SupportBundleService()
    private let ownershipService = EnvironmentOwnershipService()
    private let compatibilityResolver = CompatibilityResolver()
    private let profileMatcher = CompatibilityProfileMatcher()
    private let dxmtBridgeValidator = DXMTBridgeValidator()
    private lazy var deletionCoordinator = EnvironmentDeletionCoordinator(
        store: store,
        ownershipService: ownershipService,
        rootURL: JSONStillStore.defaultRootURL()
    )
    private lazy var restoreCoordinator = EnvironmentRestoreCoordinator(
        store: store,
        backupService: backupService,
        ownershipService: ownershipService,
        rootURL: JSONStillStore.defaultRootURL()
    )

    @Published var destination: SidebarDestination {
        didSet { UserDefaults.standard.set(destination.rawValue, forKey: "sidebarDestination") }
    }
    @Published var environments: [WindowsEnvironment] = []
    @Published var applications: [LibraryApplication] = []
    @Published var launchEntries: [LaunchEntry] = []
    @Published var operations: [StillOperation] = []
    @Published var sessions: [LaunchSession] = []
    @Published var installedEngines: [EngineDescriptor] = []
    @Published var selectedApplicationID: LibraryApplication.ID? {
        didSet { persist(selectedApplicationID, key: "selectedApplicationID") }
    }
    @Published var selectedEnvironmentID: WindowsEnvironment.ID? {
        didSet { persist(selectedEnvironmentID, key: "selectedEnvironmentID") }
    }
    @Published var searchText = ""
    @Published var presentation: LibraryPresentation {
        didSet { UserDefaults.standard.set(presentation.rawValue, forKey: "libraryPresentation") }
    }
    @Published var inspectorPresented: Bool {
        didSet { UserDefaults.standard.set(inspectorPresented, forKey: "inspectorPresented") }
    }
    @Published var libraryState: FeatureLoadState = .idle
    @Published var installState: FeatureLoadState = .idle
    @Published var activityState: FeatureLoadState = .idle
    @Published var installDraft = InstallDraft()
    @Published var errorMessage: String?
    @Published var pendingForceTermination: PendingForceTermination?
    @Published var developerModeEnabled: Bool {
        didSet { UserDefaults.standard.set(developerModeEnabled, forKey: "developerModeEnabled") }
    }
    @Published var closeRunningBehavior: CloseRunningBehavior {
        didSet { UserDefaults.standard.set(closeRunningBehavior.rawValue, forKey: "closeRunningBehavior") }
    }
    @Published var showsDeveloperModeExplanation = false
    @Published var showsDeveloperDisableAudit = false
    @Published var deletionPreview: EnvironmentDeletionPreview?
    @Published var pendingEnvironmentRemoval: WindowsEnvironment?
    @Published var selectedDeletionMethod: EnvironmentDeletionMethod {
        didSet { UserDefaults.standard.set(selectedDeletionMethod.rawValue, forKey: "environmentDeletionMethod") }
    }
    @Published var rememberDeletionMethod = false
    @Published var suppressDeletionExplanation: Bool {
        didSet { UserDefaults.standard.set(suppressDeletionExplanation, forKey: "suppressDeletionExplanation") }
    }
    @Published var requiresPermanentDeletionConfirmation = false
    @Published var repairReport: RepairReport?
    @Published var latestRestorePoint: RestorePointManifest?
    @Published var logRetentionDays: Int {
        didSet {
            UserDefaults.standard.set(logRetentionDays, forKey: "logRetentionDays")
            do {
                _ = try logRotationService.rotate(retentionDays: logRetentionDays)
            } catch {
                errorMessage = "Log retention could not be applied: \(error.localizedDescription)"
            }
        }
    }
    @Published var pendingDiscoveryCandidates: [PendingDiscoveryCandidate] = []
    @Published var supportBundleDraft: SupportBundleDraft?
    @Published var supportBundleExportedURL: URL?

    init() {
        let defaults = UserDefaults.standard
        let restoredDeveloperMode = defaults.bool(forKey: "developerModeEnabled")
        developerModeEnabled = restoredDeveloperMode
        closeRunningBehavior = CloseRunningBehavior(
            rawValue: UserDefaults.standard.string(forKey: "closeRunningBehavior") ?? ""
        ) ?? .ask
        selectedDeletionMethod = EnvironmentDeletionMethod(
            rawValue: UserDefaults.standard.string(forKey: "environmentDeletionMethod") ?? ""
        ) ?? .moveToTrash
        suppressDeletionExplanation = UserDefaults.standard.bool(forKey: "suppressDeletionExplanation")
        let savedRetention = UserDefaults.standard.integer(forKey: "logRetentionDays")
        logRetentionDays = savedRetention == 0 ? 14 : savedRetention
        let restoredDestination = SidebarDestination(
            rawValue: defaults.string(forKey: "sidebarDestination") ?? ""
        ) ?? .allApplications
        if !restoredDeveloperMode && !restoredDestination.isLibrary
            && ![.install, .activity, .environments].contains(restoredDestination) {
            destination = .allApplications
        } else {
            destination = restoredDestination
        }
        selectedApplicationID = defaults.string(forKey: "selectedApplicationID")
            .flatMap(UUID.init(uuidString:))
        selectedEnvironmentID = defaults.string(forKey: "selectedEnvironmentID")
            .flatMap(UUID.init(uuidString:))
        presentation = LibraryPresentation(
            rawValue: defaults.string(forKey: "libraryPresentation") ?? ""
        ) ?? .grid
        inspectorPresented = defaults.object(forKey: "inspectorPresented") == nil
            ? true
            : defaults.bool(forKey: "inspectorPresented")
    }

    var selectedApplication: LibraryApplication? {
        applications.first { $0.id == selectedApplicationID }
    }

    var selectedEnvironment: WindowsEnvironment? {
        environments.first { $0.id == selectedEnvironmentID }
    }

    var selectedSession: LaunchSession? {
        guard let applicationID = selectedApplicationID else { return nil }
        return sessions.first { $0.applicationID == applicationID && $0.state.isActive }
    }

    var hasCustomCompatibility: Bool {
        applications.contains { $0.selectedProfileID == "custom" }
    }

    var matchedInstallerProfile: CompatibilityProfile? {
        guard let url = installDraft.installerURL else { return nil }
        let name = url.lastPathComponent.lowercased()
        guard BundledApplicationRecipes.steam.installer?
            .acceptedFileNames.contains(name) == true else { return nil }
        return BundledCompatibilityProfiles.steam
    }

    var visibleApplications: [LibraryApplication] {
        applications.filter { application in
            guard !application.isHidden else { return false }
            let matchesSearch = searchText.isEmpty
                || application.name.localizedCaseInsensitiveContains(searchText)
            guard matchesSearch else { return false }
            switch destination {
            case .favorites: return application.isFavorite
            case .games: return application.category == .game
            case .applications:
                return application.category != .game
                    && application.category != .launcher
            case .recent: return application.lastLaunchedAt != nil
            default: return true
            }
        }.sorted { lhs, rhs in
            if destination == .recent {
                return (lhs.lastLaunchedAt ?? .distantPast)
                    > (rhs.lastLaunchedAt ?? .distantPast)
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var libraryDestinations: [SidebarDestination] {
        var values: [SidebarDestination] = [.allApplications]
        if applications.contains(where: \.isFavorite) { values.append(.favorites) }
        if applications.contains(where: { $0.category == .game }) { values.append(.games) }
        if applications.contains(where: {
            $0.category != .game && $0.category != .launcher
        }) { values.append(.applications) }
        if applications.contains(where: { $0.lastLaunchedAt != nil }) { values.append(.recent) }
        return values
    }

    func load(scanRegisteredEnvironments: Bool = true) async {
        libraryState = .loading
        activityState = .loading
        do {
            _ = try logRotationService.rotate(retentionDays: logRetentionDays)
            _ = try await deletionCoordinator.recoverInterruptedDeletions()
            _ = try await restoreCoordinator.recoverInterruptedRestores()
            _ = try await store.recoverInterruptedOperations()
            var document = try await store.load()
            environments = document.environments
            applications = document.applications
            launchEntries = document.launchEntries
            operations = document.operations.sorted { $0.createdAt > $1.createdAt }
            installedEngines = await engineInstaller.installedDescriptors()
            let installedBuilds = try installedEngines.map(runtimeBuild)
            try await store.synchronizeInstalledEngineBuilds(installedBuilds)
            document = try await store.load()
            environments = document.environments
            var discoveryFailureCount = 0
            if scanRegisteredEnvironments, !environments.isEmpty {
                let summary = await discoverApplications(environmentID: nil)
                discoveryFailureCount = summary.failureCount
                pendingDiscoveryCandidates = summary.pending
                document = try await store.load()
                environments = document.environments
                applications = document.applications
                launchEntries = document.launchEntries
                operations = document.operations.sorted { $0.createdAt > $1.createdAt }
            }
            if !applications.contains(where: { $0.id == selectedApplicationID }) {
                selectedApplicationID = applications.first?.id
            }
            if !environments.contains(where: { $0.id == selectedEnvironmentID }) {
                selectedEnvironmentID = environments.first?.id
            }
            libraryState = discoveryFailureCount == 0
                ? .success(applications.isEmpty ? nil : "Library updated.")
                : .partial("Some Environments could not be scanned.")
            activityState = .success(nil)
        } catch {
            libraryState = .recovery(error.localizedDescription)
            activityState = .failure(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func chooseLocalInstaller() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows installer"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.init(filenameExtension: "exe") ?? .data,
                                     .init(filenameExtension: "msi") ?? .data]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        installDraft.installerURL = panel.url
        if installDraft.environmentID == nil {
            installDraft.environmentID = environments.first?.id
        }
        installState = .success("Local installer selected.")
    }

    func createEnvironment(name: String? = nil) async {
        installState = .loading
        do {
            guard let engine = installedEngines.first else {
                throw StillCoreError.noInstalledEngine
            }
            let environmentID = UUID()
            let displayName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = displayName?.isEmpty == false
                ? displayName!
                : "Environment \(environments.count + 1)"
            let root = ownershipService.managedPrefixURL(for: environmentID)
            let document = try await store.load()
            let environment = WindowsEnvironment(
                id: environmentID,
                name: resolvedName,
                prefixURL: root,
                pinnedEngineBuildID: engine.id,
                provisionedEngineBuildID: engine.id,
                ownership: .managed,
                managementNonce: UUID()
            )
            do {
                try ownershipService.writeMarker(
                    for: environment,
                    storeIdentifier: document.storeIdentifier
                )
                try await store.saveEnvironment(environment)
            } catch {
                if FileManager.default.fileExists(atPath: root.path) {
                    try? FileManager.default.removeItem(at: root)
                }
                throw error
            }
            installDraft.environmentID = environment.id
            selectedEnvironmentID = environment.id
            await load()
            destination = .install
            installState = .success("Environment created.")
        } catch {
            installState = .failure(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func importEnvironment() async {
        let panel = NSOpenPanel()
        panel.title = "Choose a Wine prefix"
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let prefixURL = panel.url else { return }
        installState = .loading
        do {
            let environment = WindowsEnvironment(
                name: prefixURL.lastPathComponent,
                prefixURL: prefixURL,
                pinnedEngineBuildID: installedEngines.first?.id,
                provisionedEngineBuildID: installedEngines.first?.id,
                ownership: .importedInPlace
            )
            try await store.saveEnvironment(environment)
            await load()
            selectedEnvironmentID = environment.id
            destination = .environments
            installState = .success("Environment imported without moving its files.")
        } catch {
            installState = .failure(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func runSelectedInstaller() async {
        guard let installerURL = installDraft.installerURL,
              let environmentID = installDraft.environmentID,
              let environment = environments.first(where: { $0.id == environmentID }) else {
            installState = .failure("Choose a local installer and an Environment.")
            return
        }
        installState = .loading
        var operation = StillOperation(kind: .launchInstaller, environmentID: environment.id)
        do {
            var effectiveEnvironment = environment
            let installerArguments: [String]
            if let matchedInstallerProfile {
                effectiveEnvironment.profileID = matchedInstallerProfile.id
                effectiveEnvironment.updatedAt = .now
                try await store.saveEnvironment(effectiveEnvironment)
                installerArguments = BundledApplicationRecipes.steam.installer?.arguments ?? []
            } else {
                installerArguments = []
            }
            try operation.transition(to: .running)
            try await store.saveOperation(operation)
            let engine = try engine(for: effectiveEnvironment)
            let session = try await LocalWineEngine(
                descriptor: engine,
                processSupervisor: supervisor
            ).launch(LaunchRequest(
                bottle: bottle(from: effectiveEnvironment),
                executableURL: installerURL,
                arguments: installerArguments,
                environmentID: effectiveEnvironment.id
            ))
            sessions.append(session)
            operation.appendEvent("The local installer was launched.")
            try operation.transition(to: .succeeded, resultSummary: "Installer launched")
            try await store.saveOperation(operation)
            installState = .success("Installer launched. Scan after installation finishes.")
            await refreshActivity()
        } catch {
            if operation.state == .running {
                try? operation.transition(to: .failed, resultSummary: error.localizedDescription)
                try? await store.saveOperation(operation)
            }
            installState = .failure(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func scanApplications(environmentID: WindowsEnvironment.ID? = nil) async {
        libraryState = .loading
        let summary = await discoverApplications(environmentID: environmentID)
        pendingDiscoveryCandidates = summary.pending
        await load(scanRegisteredEnvironments: false)
        libraryState = summary.failureCount == 0
            ? .success("Application scan completed.")
            : .partial("Some Environments could not be scanned.")
    }

    private func discoverApplications(
        environmentID: WindowsEnvironment.ID?
    ) async -> (failureCount: Int, pending: [PendingDiscoveryCandidate]) {
        var failureCount = 0
        var pending: [PendingDiscoveryCandidate] = []
        for environment in environments
        where environmentID == nil || environment.id == environmentID {
            let result = discoveryCoordinator.discover(in: bottle(from: environment))
            if !result.providerFailures.isEmpty || !result.providerWarnings.isEmpty {
                failureCount += 1
            }
            do {
                for candidate in result.accepted {
                    try await persist(
                        candidate,
                        environment: environment,
                        generation: result.generation
                    )
                }
                let candidates = result.accepted + result.requiresConfirmation
                for providerID in result.reconcilableProviderIDs {
                    let discoveredItemIDs: Set<String> = Set(candidates.compactMap {
                        candidate -> String? in
                        guard candidate.providerID == providerID else { return nil }
                        return candidate.application.sourceIdentifier
                            ?? candidate.application.id
                    })
                    try await store.reconcileDiscoveredApplications(
                        environmentID: environment.id,
                        providerID: providerID,
                        discoveredProviderItemIDs: discoveredItemIDs
                    )
                }
                pending.append(contentsOf: result.requiresConfirmation.map {
                    PendingDiscoveryCandidate(environmentID: environment.id, candidate: $0)
                })
            } catch {
                failureCount += 1
            }
        }
        return (failureCount, pending)
    }

    func confirmDiscovery(_ pending: PendingDiscoveryCandidate) async {
        guard let environment = environments.first(
            where: { $0.id == pending.environmentID }
        ) else { return }
        do {
            try await persist(
                pending.candidate,
                environment: environment,
                generation: UUID()
            )
            pendingDiscoveryCandidates.removeAll { $0.id == pending.id }
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    func ignoreDiscovery(_ pending: PendingDiscoveryCandidate) {
        pendingDiscoveryCandidates.removeAll { $0.id == pending.id }
    }

    func launchSelectedApplication() async {
        guard var application = selectedApplication,
              let environment = environments.first(where: { $0.id == application.environmentID }),
              let entryID = application.launchEntryIDs.first,
              let entry = launchEntries.first(where: { $0.id == entryID }) else { return }
        do {
            if let state = application.providerManagedState, state != .installed {
                throw StillCoreError.invalidApplicationState(
                    "\(state.rawValue) (managed by \(application.providerID ?? "provider"))"
                )
            }
            let engine = try engine(for: environment)
            let document = try await store.load()
            let engineBuild = try runtimeBuild(for: engine)
            let profile = profileMatcher.profile(
                for: application,
                executableURL: entry.executableURL,
                profiles: BundledCompatibilityProfiles.all
            )
            let effective = try compatibilityResolver.resolve(
                environment: environment,
                profile: profile,
                engineFamily: engineBuild.family,
                registry: CapabilityRegistry(
                    host: currentHostCapabilities(),
                    engine: engineBuild,
                    components: document.components,
                    bridgeAvailability: engine.capabilities.contains(.dxmt)
                        ? dxmtBridgeValidator.validate(engine: engine)
                        : nil
                )
            )
            var effectiveEnvironment = environment
            effectiveEnvironment.windowsVersion = effective.windowsVersion.value
            effectiveEnvironment.graphicsBackend = effective.graphicsBackend.value
            effectiveEnvironment.enhancedSync = effective.enhancedSync.value
            let effectiveBottle = bottle(from: effectiveEnvironment)
            var launchEnvironment = effective.environmentVariables.mapValues(\.value)
            var resolvedArguments = entry.arguments
            if profile?.id == BundledCompatibilityProfiles.steam.id {
                launchEnvironment.merge(
                    SteamBootstrapper.launchEnvironment(
                        for: effectiveBottle,
                        executableURL: entry.executableURL
                    ),
                    uniquingKeysWith: { _, profileValue in profileValue }
                )
                resolvedArguments = mergedArguments(
                    resolvedArguments,
                    SteamBootstrapper.launchArguments(for: effectiveBottle)
                )
            }
            resolvedArguments = mergedArguments(
                resolvedArguments,
                effective.launchArguments
            )
            let session = try await LocalWineEngine(
                descriptor: engine,
                processSupervisor: supervisor
            ).launch(LaunchRequest(
                bottle: effectiveBottle,
                executableURL: entry.executableURL,
                arguments: resolvedArguments,
                environment: launchEnvironment,
                workingDirectoryURL: entry.workingDirectoryURL,
                applicationID: application.id,
                environmentID: environment.id
            ))
            sessions.append(session)
            application.lastLaunchedAt = .now
            try await store.saveApplication(
                application,
                launchEntries: launchEntries.filter { $0.applicationID == application.id }
            )
            await load()
            selectedApplicationID = application.id
            activityState = .success("\(application.name) started.")
        } catch {
            activityState = .failure(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func toggleFavorite(_ application: LibraryApplication) async {
        var updated = application
        updated.isFavorite.toggle()
        do {
            try await store.saveApplication(
                updated,
                launchEntries: launchEntries.filter { $0.applicationID == updated.id }
            )
            await load()
            selectedApplicationID = updated.id
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshActivity() async {
        operations = (try? await store.operations()) ?? []
        sessions = await supervisor.activeSessions()
        activityState = .success(nil)
    }

    func stopSelectedNormally() async {
        guard let session = selectedSession else { return }
        do {
            try await supervisor.stop(sessionID: session.id)
            await refreshActivity()
        } catch { errorMessage = error.localizedDescription }
    }

    func stopAllNormally() async {
        await supervisor.stopAll()
        await refreshActivity()
    }

    func requestForceStopSelected() {
        guard let session = selectedSession else { return }
        pendingForceTermination = .selected(
            session.id,
            selectedApplication?.name ?? "Selected Application"
        )
    }

    func requestForceStopAll() {
        guard !sessions.isEmpty else { return }
        pendingForceTermination = .all(sessions.count)
    }

    func confirmForceTermination() async {
        guard let pendingForceTermination else { return }
        self.pendingForceTermination = nil
        do {
            switch pendingForceTermination {
            case .selected(let id, _):
                try await supervisor.forceStop(sessionID: id)
            case .all:
                await supervisor.forceStopAll()
            }
            await refreshActivity()
        } catch { errorMessage = error.localizedDescription }
    }

    func setDeveloperMode(_ enabled: Bool) {
        if enabled {
            developerModeEnabled = true
            if !UserDefaults.standard.bool(forKey: "developerModeExplanationDismissed") {
                showsDeveloperModeExplanation = true
            }
        } else if hasCustomCompatibility {
            showsDeveloperDisableAudit = true
        } else {
            developerModeEnabled = false
        }
    }

    func disableDeveloperModeKeepingOverrides(_ keep: Bool) async {
        showsDeveloperDisableAudit = false
        if !keep {
            for application in applications where application.selectedProfileID == "custom" {
                var updated = application
                updated.selectedProfileID = nil
                try? await store.saveApplication(
                    updated,
                    launchEntries: launchEntries.filter { $0.applicationID == updated.id }
                )
            }
            await load()
        }
        developerModeEnabled = false
        if !destination.isLibrary
            && ![.install, .activity, .environments].contains(destination) {
            destination = .allApplications
        }
    }

    func prepareSupportBundle() async {
        do {
            let document = try await store.load()
            supportBundleDraft = try supportBundleService.makeDraft(
                document: document,
                engines: installedEngines
            )
        } catch {
            errorMessage = "Support Bundle preview could not be prepared: \(error.localizedDescription)"
        }
    }

    func exportSupportBundle(_ draft: SupportBundleDraft, to destinationURL: URL) {
        do {
            try supportBundleService.export(draft, to: destinationURL)
            supportBundleDraft = nil
            supportBundleExportedURL = destinationURL
        } catch {
            errorMessage = "Support Bundle could not be exported: \(error.localizedDescription)"
        }
    }

    func revealSelectedApplication() {
        guard let application = selectedApplication,
              let entryID = application.launchEntryIDs.first,
              let entry = launchEntries.first(where: { $0.id == entryID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.executableURL])
    }

    func createRestorePoint(for environment: WindowsEnvironment) async {
        var operation = StillOperation(kind: .createRestorePoint, environmentID: environment.id)
        do {
            try operation.transition(to: .running)
            try await store.saveOperation(operation)
            latestRestorePoint = try await restorePointService.create(
                environment: environment,
                applications: applications,
                launchEntries: launchEntries,
                activeSessions: sessions
            )
            try operation.transition(to: .succeeded, resultSummary: "Restore Point created")
            try await store.saveOperation(operation)
            await refreshActivity()
        } catch {
            if operation.state == .running {
                try? operation.transition(to: .failed, resultSummary: error.localizedDescription)
                try? await store.saveOperation(operation)
            }
            errorMessage = error.localizedDescription
        }
    }

    func duplicate(_ environment: WindowsEnvironment) async {
        var operation = StillOperation(kind: .duplicateEnvironment, environmentID: environment.id)
        do {
            try operation.transition(to: .running)
            try await store.saveOperation(operation)
            let duplicate = try recoveryService.duplicate(
                environment,
                name: "\(environment.name) Copy",
                managedRootURL: ownershipService.managedRootURL,
                activeSessions: sessions
            )
            do {
                let document = try await store.load()
                try ownershipService.writeMarker(
                    for: duplicate,
                    storeIdentifier: document.storeIdentifier
                )
                try await store.saveEnvironment(duplicate)
            } catch {
                if FileManager.default.fileExists(atPath: duplicate.prefixURL.path) {
                    try? FileManager.default.removeItem(at: duplicate.prefixURL)
                }
                throw error
            }
            try operation.transition(to: .succeeded, resultSummary: "Environment duplicated")
            try await store.saveOperation(operation)
            await load()
            selectedEnvironmentID = duplicate.id
        } catch {
            if operation.state == .running {
                try? operation.transition(to: .failed, resultSummary: error.localizedDescription)
                try? await store.saveOperation(operation)
            }
            errorMessage = error.localizedDescription
        }
    }

    func inspectRepair(_ environment: WindowsEnvironment) async {
        let document = try? await store.load()
        let profile = BundledCompatibilityProfiles.all.first { $0.id == environment.profileID }
        let environmentApplicationIDs = Set(
            applications.filter { $0.environmentID == environment.id }.map(\.id)
        )
        repairReport = repairService.inspect(
            environment: environment,
            engineBuilds: document?.engineBuilds ?? [],
            components: document?.components ?? [],
            profile: profile,
            launchEntries: launchEntries.filter {
                environmentApplicationIDs.contains($0.applicationID)
            }
        )
    }

    func exportBackup(
        environment: WindowsEnvironment,
        destinationURL: URL,
        encrypted: Bool,
        password: String?
    ) async {
        var operation = StillOperation(kind: .backup, environmentID: environment.id)
        do {
            try operation.transition(to: .running)
            try await store.saveOperation(operation)
            let document = try await store.load()
            let preview = try await backupService.preview(
                environment: environment,
                applications: applications,
                launchEntries: launchEntries,
                components: document.components,
                destinationURL: destinationURL,
                encrypted: encrypted
            )
            _ = try await backupService.create(
                preview: preview,
                password: password,
                activeSessions: sessions
            )
            try operation.transition(to: .succeeded, resultSummary: "Backup exported")
            try await store.saveOperation(operation)
            await refreshActivity()
        } catch {
            if operation.state == .running {
                try? operation.transition(to: .failed, resultSummary: error.localizedDescription)
                try? await store.saveOperation(operation)
            }
            errorMessage = error.localizedDescription
        }
    }

    func prepareDeletion(_ environment: WindowsEnvironment) async {
        guard StabilizationGate.physicalEnvironmentDeletionEnabled else {
            errorMessage = "Physical deletion is temporarily unavailable until Still can prove Environment ownership and roll back interrupted file operations. Use Remove from Still to keep the files in place."
            return
        }
        do {
            let document = try await store.load()
            try ownershipService.validateManagedOwnership(
                of: environment,
                storeIdentifier: document.storeIdentifier
            )
            deletionPreview = try recoveryService.deletionPreview(
                environment: environment,
                applications: applications
            )
        } catch { errorMessage = error.localizedDescription }
    }

    func restoreBackup(at backupURL: URL, password: String?) async {
        do {
            let restoredEnvironment = try await restoreCoordinator.restore(
                backupURL: backupURL,
                password: password?.isEmpty == true ? nil : password,
                activeSessions: sessions
            )
            await load()
            selectedEnvironmentID = restoredEnvironment.id
            destination = .environments
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestEnvironmentRemoval(_ environment: WindowsEnvironment) {
        pendingEnvironmentRemoval = environment
    }

    func confirmEnvironmentRemoval() async {
        guard let environment = pendingEnvironmentRemoval else { return }
        do {
            try await store.deleteEnvironmentRecord(id: environment.id)
            pendingEnvironmentRemoval = nil
            await load()
            activityState = .success("\(environment.name) was removed from Still. Its files were not changed.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func continueDeletion() async {
        guard let preview = deletionPreview else { return }
        if selectedDeletionMethod == .permanentlyDelete {
            requiresPermanentDeletionConfirmation = true
        } else {
            await performDeletion(preview: preview, permanentConfirmed: false)
        }
    }

    func confirmPermanentDeletion() async {
        requiresPermanentDeletionConfirmation = false
        guard let preview = deletionPreview else { return }
        await performDeletion(preview: preview, permanentConfirmed: true)
    }

    private func performDeletion(
        preview: EnvironmentDeletionPreview,
        permanentConfirmed: Bool
    ) async {
        do {
            guard let environment = environments.first(where: {
                $0.id == preview.environmentID
            }) else {
                throw StillCoreError.invalidStore(
                    "The Environment selected for deletion no longer exists."
                )
            }
            try await deletionCoordinator.delete(
                environment: environment,
                method: selectedDeletionMethod,
                activeSessions: sessions,
                finalPermanentConfirmation: permanentConfirmed
            )
            if rememberDeletionMethod {
                UserDefaults.standard.set(selectedDeletionMethod.rawValue, forKey: "environmentDeletionMethod")
            }
            deletionPreview = nil
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func persist(_ id: UUID?, key: String) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func engine(for environment: WindowsEnvironment) throws -> EngineDescriptor {
        guard let id = environment.pinnedEngineBuildID,
              let engine = installedEngines.first(where: { $0.id == id }) else {
            throw StillCoreError.engineNotFound(environment.pinnedEngineBuildID ?? "unassigned")
        }
        return engine
    }

    private func runtimeBuild(for engine: EngineDescriptor) throws -> EngineBuild {
        let bundledManifest = try? BundledEngineCatalog.manifest(id: engine.id)
        guard let family = engine.family ?? bundledManifest?.family else {
            throw StillCoreError.invalidEngineInstallation(engine.wineBinaryURL)
        }
        return EngineBuild(
            id: engine.id,
            family: family,
            displayName: engine.displayName,
            version: engine.version,
            installURL: engine.wineBinaryURL.deletingLastPathComponent(),
            capabilities: engine.capabilities,
            manifestID: bundledManifest?.id,
            sourceArchiveSHA256: engine.sourceArchiveSHA256,
            artifactManifestSHA256: engine.artifactManifestSHA256
        )
    }

    private func currentHostCapabilities() -> HostCapabilitySnapshot {
#if arch(arm64)
        let architecture = HostCapabilitySnapshot.Architecture.arm64
        let supportsRosetta = FileManager.default.fileExists(
            atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime"
        )
#else
        let architecture = HostCapabilitySnapshot.Architecture.x86_64
        let supportsRosetta = true
#endif
        return HostCapabilitySnapshot(
            architecture: architecture,
            supportsMetal: MTLCreateSystemDefaultDevice() != nil,
            supportsRosetta: supportsRosetta
        )
    }

    private func mergedArguments(_ base: [String], _ additions: [String]) -> [String] {
        var result = base
        for argument in additions where !result.contains(argument) {
            result.append(argument)
        }
        return result
    }

    private func bottle(from environment: WindowsEnvironment) -> Bottle {
        Bottle(
            id: environment.id,
            name: environment.name,
            prefixURL: environment.prefixURL,
            engineID: environment.pinnedEngineBuildID,
            provisionedEngineID: environment.provisionedEngineBuildID,
            recipeID: environment.profileID,
            graphicsBackend: environment.graphicsBackend,
            windowsVersion: environment.windowsVersion,
            enhancedSync: environment.enhancedSync,
            metalHUDEnabled: environment.metalHUDEnabled,
            metalTraceEnabled: environment.metalTraceEnabled,
            createdAt: environment.createdAt,
            updatedAt: environment.updatedAt
        )
    }

    private func persist(
        _ candidate: DiscoveredApplicationCandidate,
        environment: WindowsEnvironment,
        generation: UUID
    ) async throws {
        let item = candidate.application
        let applicationID = StableID.derived(
            from: "application:\(environment.id):\(candidate.providerID):\(item.sourceIdentifier ?? item.id)"
        )
        let entryID = StableID.derived(from: "launch:\(applicationID):primary")
        let existing = applications.first { $0.id == applicationID }
        var application = LibraryApplication(
            id: applicationID,
            environmentID: environment.id,
            name: item.name,
            category: candidate.category,
            providerID: candidate.providerID,
            providerItemID: item.sourceIdentifier ?? item.id,
            launchEntryIDs: [entryID],
            selectedProfileID: nil,
            isFavorite: existing?.isFavorite ?? false,
            isHidden: existing?.isHidden ?? false,
            lastLaunchedAt: existing?.lastLaunchedAt,
            providerManagedState: candidate.providerManagedState,
            lastDiscoveryGeneration: generation
        )
        application.selectedProfileID = profileMatcher.profileIDForDiscovery(
            existingSelection: existing?.selectedProfileID,
            application: application,
            executableURL: item.launcherURL,
            profiles: BundledCompatibilityProfiles.all
        )
        try await store.saveApplication(application, launchEntries: [
            LaunchEntry(
                id: entryID,
                applicationID: applicationID,
                executableURL: item.launcherURL,
                arguments: item.launchArguments,
                workingDirectoryURL: item.installDirectoryURL
            )
        ])
    }
}
