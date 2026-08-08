import AppKit
import Darwin
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
    private let engineInstaller = EngineInstaller()
    private let discoveryCoordinator = ApplicationDiscoveryCoordinator()
    private let supervisor = ProcessSupervisor()
    private let environmentOperationCoordinator = EnvironmentOperationCoordinator()
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
    private let windowActivator: WineWindowActivating
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
        didSet {
            UserDefaults.standard.set(destination.rawValue, forKey: "sidebarDestination")
            reconcileVisibleApplicationSelection()
        }
    }
    @Published var environments: [WindowsEnvironment] = []
    @Published var applications: [LibraryApplication] = []
    @Published var launchEntries: [LaunchEntry] = []
    @Published var operations: [StillOperation] = []
    @Published var sessions: [LaunchSession] = []
    @Published var launchingApplicationIDs: Set<LibraryApplication.ID> = []
    @Published var liveEnvironmentIDs: Set<WindowsEnvironment.ID> = []
    @Published var performanceSnapshots: [LibraryApplication.ID: RuntimePerformanceSnapshot] = [:]
    @Published var installedEngines: [EngineDescriptor] = []
    @Published var selectedApplicationID: LibraryApplication.ID? {
        didSet { persist(selectedApplicationID, key: "selectedApplicationID") }
    }
    @Published var selectedEnvironmentID: WindowsEnvironment.ID? {
        didSet { persist(selectedEnvironmentID, key: "selectedEnvironmentID") }
    }
    @Published var searchText = "" {
        didSet { reconcileVisibleApplicationSelection() }
    }
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
    @Published var launchNotice: String?
    @Published var pendingWindowControlApplicationID: LibraryApplication.ID?
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
    @Published var pendingRestorePointRestore: RestorePointManifest?
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
    private var acceptedEngineLicenseIDs: Set<String> = []
    private var performanceSamplingTasks: [LibraryApplication.ID: Task<Void, Never>] = [:]
    private var backgroundDiscoveryTask: Task<Void, Never>?

    init(windowActivator: WineWindowActivating = WineWindowActivator()) {
        self.windowActivator = windowActivator
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

    var hasLiveWineActivity: Bool {
        !sessions.isEmpty || !liveEnvironmentIDs.isEmpty
    }

    func runtimeState(for application: LibraryApplication) -> ApplicationRuntimeState {
        if launchingApplicationIDs.contains(application.id) { return .launching }
        if let session = sessions.first(where: {
            $0.applicationID == application.id && $0.state.isActive
        }) {
            return session.state == .stopping ? .stopping : .running
        }
        return .idle
    }

    func recentFailures(for application: LibraryApplication) -> [StillOperation] {
        operations.filter {
            $0.applicationID == application.id && $0.state == .failed
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func effectiveProfileID(for application: LibraryApplication) -> String? {
        guard let entryID = application.launchEntryIDs.first,
              let entry = launchEntries.first(where: { $0.id == entryID }) else {
            return application.selectedProfileID
        }
        return profileMatcher.profile(
            for: application,
            executableURL: entry.executableURL,
            profiles: BundledCompatibilityProfiles.all
        )?.id ?? application.selectedProfileID
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
            var document = try await store.load()
            environments = document.environments
            applications = document.applications
            launchEntries = document.launchEntries
            operations = document.operations.sorted { $0.createdAt > $1.createdAt }
            installedEngines = await engineInstaller.installedDescriptors()
            acceptedEngineLicenseIDs = await engineInstaller.acceptedLicenseIDs()
            let installedBuilds = try installedEngines.map(runtimeBuild)
            try await store.synchronizeInstalledEngineBuilds(installedBuilds)
            document = try await store.load()
            environments = document.environments
            reconcileVisibleApplicationSelection()
            if !environments.contains(where: { $0.id == selectedEnvironmentID }) {
                selectedEnvironmentID = environments.first?.id
            }
            await reconcileLiveWineSessions()
            _ = try await store.recoverInterruptedOperations(
                activeApplicationIDs: Set(sessions.compactMap(\.applicationID))
            )
            operations = (try? await store.operations()) ?? operations
            libraryState = .success(applications.isEmpty ? nil : "Library updated.")
            activityState = .success(nil)
            if scanRegisteredEnvironments, !environments.isEmpty {
                scheduleBackgroundDiscovery()
            }
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
            try await withEnvironmentLease(operation) {
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
            }
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
        backgroundDiscoveryTask?.cancel()
        libraryState = .loading
        let summary = await discoverApplications(environmentID: environmentID)
        pendingDiscoveryCandidates = summary.pending
        await load(scanRegisteredEnvironments: false)
        libraryState = summary.failureCount == 0
            ? .success("Application scan completed.")
            : .partial("Some Environments could not be scanned.")
    }

    private func scheduleBackgroundDiscovery() {
        backgroundDiscoveryTask?.cancel()
        backgroundDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            let summary = await self.discoverApplications(environmentID: nil)
            guard !Task.isCancelled else { return }
            self.pendingDiscoveryCandidates = summary.pending
            do {
                let document = try await self.store.load()
                self.environments = document.environments
                self.applications = document.applications
                self.launchEntries = document.launchEntries
                self.operations = document.operations.sorted { $0.createdAt > $1.createdAt }
                await self.reconcileLiveWineSessions()
                self.libraryState = summary.failureCount == 0
                    ? .success("Application scan completed.")
                    : .partial("Some Environments could not be scanned.")
            } catch {
                self.libraryState = .partial("The background application scan could not be applied.")
            }
        }
    }

    private func discoverApplications(
        environmentID: WindowsEnvironment.ID?
    ) async -> (failureCount: Int, pending: [PendingDiscoveryCandidate]) {
        var failureCount = 0
        var pending: [PendingDiscoveryCandidate] = []
        let targets = environments.filter {
            environmentID == nil || $0.id == environmentID
        }
        let coordinator = discoveryCoordinator
        let discoveries = await withTaskGroup(
            of: (WindowsEnvironment, DiscoveryResult).self,
            returning: [(WindowsEnvironment, DiscoveryResult)].self
        ) { group in
            for environment in targets {
                let targetBottle = bottle(from: environment)
                group.addTask {
                    (environment, coordinator.discover(in: targetBottle))
                }
            }
            var values: [(WindowsEnvironment, DiscoveryResult)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0.name < $1.0.name }
        }
        for (environment, result) in discoveries {
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
            await load(scanRegisteredEnvironments: false)
        } catch { errorMessage = error.localizedDescription }
    }

    func ignoreDiscovery(_ pending: PendingDiscoveryCandidate) {
        pendingDiscoveryCandidates.removeAll { $0.id == pending.id }
    }

    func performPrimaryApplicationAction(applicationID: LibraryApplication.ID? = nil) async {
        let targetID = applicationID ?? selectedApplicationID
        guard let targetID,
              let application = applications.first(where: { $0.id == targetID }) else { return }
        switch runtimeState(for: application) {
        case .idle:
            await launchApplication(applicationID: targetID)
        case .launching, .stopping:
            return
        case .running:
            await openRunningApplication(application)
        }
    }

    func launchSelectedApplication() async {
        guard let applicationID = selectedApplicationID else { return }
        await launchApplication(applicationID: applicationID)
    }

    func launchApplication(applicationID: LibraryApplication.ID) async {
        guard var application = applications.first(where: { $0.id == applicationID }),
              let environment = environments.first(where: { $0.id == application.environmentID }),
              let entryID = application.launchEntryIDs.first,
              let entry = launchEntries.first(where: { $0.id == entryID }) else { return }
        guard runtimeState(for: application) == .idle else {
            await performPrimaryApplicationAction(applicationID: applicationID)
            return
        }
        launchingApplicationIDs.insert(application.id)
        launchNotice = nil
        pendingWindowControlApplicationID = nil
        let launchRequestedAt = Date()
        var operation = StillOperation(
            kind: .launchApplication,
            environmentID: environment.id,
            applicationID: application.id
        )
        defer { launchingApplicationIDs.remove(application.id) }
        do {
            try await withEnvironmentLease(operation) {
                try operation.transition(to: .running)
                operation.appendEvent("Launch requested")
                try await store.saveOperation(operation)
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
                let registry = CapabilityRegistry(
                    host: currentHostCapabilities(),
                    engine: engineBuild,
                    components: document.components,
                    bridgeAvailability: engine.capabilities.contains(.dxmt)
                        ? dxmtBridgeValidator.validate(engine: engine)
                        : nil
                )
                let resolved = try compatibilityResolver.resolveLaunch(
                    application: application,
                    launchEntry: entry,
                    environment: environment,
                    profile: profile,
                    engine: engine,
                    engineBuild: engineBuild,
                    registry: registry
                )
                let pendingSession = try await LocalWineEngine(
                    descriptor: engine,
                    processSupervisor: supervisor
                ).launch(LaunchRequest(
                    bottle: resolved.bottle,
                    executableURL: entry.executableURL,
                    arguments: resolved.arguments,
                    environment: resolved.environment,
                    workingDirectoryURL: entry.workingDirectoryURL,
                    applicationID: application.id,
                    environmentID: environment.id,
                    runtimeEvidence: resolved.runtimeEvidence
                ))
                sessions = await supervisor.activeSessions()
                let observation = try await waitForApplicationObservation(
                    application: application,
                    environment: environment,
                    timeout: 30
                )
                let session = try await supervisor.confirmRunning(
                    sessionID: pendingSession.id,
                    observation: observation
                )
                sessions = await supervisor.activeSessions()
                application.lastLaunchedAt = .now
                try await store.saveApplication(
                    application,
                    launchEntries: launchEntries.filter { $0.applicationID == application.id }
                )
                try operation.transition(
                    to: .succeeded,
                    resultSummary: "Application process observed"
                )
                try await store.saveOperation(operation)
                await load(scanRegisteredEnvironments: false)
                selectedApplicationID = application.id
                activityState = .success("\(application.name) started.")
                schedulePerformanceSampling(
                    applicationID: application.id,
                    sessionID: session.id,
                    operationID: operation.id,
                    launchRequestedAt: launchRequestedAt
                )
            }
        } catch {
            if let pending = sessions.first(where: {
                $0.applicationID == application.id && $0.state == .launching
            }) {
                await supervisor.failLaunch(
                    sessionID: pending.id,
                    reason: error.localizedDescription
                )
            }
            let message = launchFailureMessage(error, applicationName: application.name)
            if operation.state == .pending {
                try? operation.transition(to: .cancelled, resultSummary: message)
            } else if operation.state == .running {
                try? operation.transition(to: .failed, resultSummary: message)
            }
            operation.appendEvent(message)
            try? await store.saveOperation(operation)
            operations = (try? await store.operations()) ?? operations
            activityState = .failure(message)
            launchNotice = message
            await reconcileLiveWineSessions()
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
            await load(scanRegisteredEnvironments: false)
            selectedApplicationID = updated.id
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshActivity() async {
        operations = (try? await store.operations()) ?? []
        sessions = await supervisor.activeSessions()
        await reconcileLiveWineSessions()
        activityState = .success(nil)
    }

    func setMetalHUDEnabled(_ enabled: Bool) async {
        guard var environment = selectedEnvironment else { return }
        environment.metalHUDEnabled = enabled
        environment.updatedAt = .now
        do {
            try await store.saveEnvironment(environment)
            await load(scanRegisteredEnvironments: false)
            activityState = .success(
                enabled
                    ? "Metal performance HUD will appear on the next launch."
                    : "Metal performance HUD disabled."
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopSelectedNormally() async {
        guard let applicationID = selectedApplicationID else { return }
        await stopApplicationNormally(applicationID: applicationID)
    }

    func stopApplicationNormally(applicationID: LibraryApplication.ID) async {
        guard let session = sessions.first(where: {
            $0.applicationID == applicationID && $0.state.isActive
        }) else { return }
        do {
            if let applicationID = session.applicationID {
                performanceSamplingTasks.removeValue(forKey: applicationID)?.cancel()
            }
            try await supervisor.stop(sessionID: session.id)
            try await waitForApplicationSessionExit(applicationID: applicationID)
            await refreshActivity()
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func stopAllNormally() async -> Bool {
        performanceSamplingTasks.values.forEach { $0.cancel() }
        performanceSamplingTasks.removeAll()
        do {
            try await terminateAllWineActivity(force: false)
            await refreshActivity()
            return true
        } catch {
            errorMessage = error.localizedDescription
            await refreshActivity()
            return false
        }
    }

    func requestForceStopSelected() {
        guard let applicationID = selectedApplicationID else { return }
        requestForceStop(applicationID: applicationID)
    }

    func requestForceStop(applicationID: LibraryApplication.ID) {
        guard let session = sessions.first(where: {
            $0.applicationID == applicationID && $0.state.isActive
        }) else { return }
        pendingForceTermination = .selected(
            session.id,
            applications.first(where: { $0.id == applicationID })?.name ?? "Selected Application"
        )
    }

    func requestForceStopAll() {
        guard hasLiveWineActivity else { return }
        pendingForceTermination = .all(max(sessions.count, liveEnvironmentIDs.count))
    }

    func confirmForceTermination() async {
        guard let pendingForceTermination else { return }
        self.pendingForceTermination = nil
        do {
            switch pendingForceTermination {
            case .selected(let id, _):
                let applicationID = sessions.first(where: { $0.id == id })?.applicationID
                try await supervisor.forceStop(sessionID: id)
                if let applicationID {
                    try await waitForApplicationSessionExit(applicationID: applicationID)
                }
            case .all:
                try await terminateAllWineActivity(force: true)
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
            try await withStoppedEnvironmentLease(operation) {
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
            }
        } catch {
            if operation.state == .running {
                try? operation.transition(to: .failed, resultSummary: error.localizedDescription)
                try? await store.saveOperation(operation)
            }
            errorMessage = error.localizedDescription
        }
    }

    func prepareLatestRestorePoint(for environment: WindowsEnvironment) async {
        do {
            guard let point = try await restorePointService.manifests(
                environmentID: environment.id
            ).first else {
                throw StillCoreError.invalidStore(
                    "No Restore Points are available for this Environment."
                )
            }
            pendingRestorePointRestore = point
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmRestorePoint() async {
        guard let point = pendingRestorePointRestore,
              let environment = environments.first(where: { $0.id == point.environmentID }) else {
            pendingRestorePointRestore = nil
            return
        }
        var operation = StillOperation(
            kind: .restoreRestorePoint,
            environmentID: environment.id
        )
        do {
            try await withStoppedEnvironmentLease(operation) {
                try operation.transition(to: .running)
                try await store.saveOperation(operation)
                _ = try await restorePointService.restore(
                    id: point.id,
                    environment: environment,
                    activeSessions: sessions,
                    store: store
                )
                try operation.transition(
                    to: .succeeded,
                    resultSummary: "Restore Point restored"
                )
                try await store.saveOperation(operation)
                pendingRestorePointRestore = nil
                await load(scanRegisteredEnvironments: false)
                selectedEnvironmentID = environment.id
                activityState = .success("Restore Point restored.")
            }
        } catch {
            if operation.state == .running {
                try? operation.transition(
                    to: .failed,
                    resultSummary: error.localizedDescription
                )
                try? await store.saveOperation(operation)
            }
            errorMessage = error.localizedDescription
        }
    }

    func changePinnedEngine(
        for environment: WindowsEnvironment,
        to engine: EngineDescriptor
    ) async {
        guard environment.pinnedEngineBuildID != engine.id else { return }

        do {
            try await withStoppedEnvironmentLease(StillOperation(
                kind: .changeEngine,
                environmentID: environment.id
            )) {
                let restorePoint = try await restorePointService.create(
                    environment: environment,
                    applications: applications,
                    launchEntries: launchEntries,
                    activeSessions: sessions
                )
                try await store.updatePinnedEngine(
                    environmentID: environment.id,
                    engineBuildID: engine.id,
                    activeSessions: sessions,
                    userApproved: true,
                    restorePointCreated: true
                )
                latestRestorePoint = restorePoint
                await load(scanRegisteredEnvironments: false)
                selectedEnvironmentID = environment.id
                activityState = .success("Engine changed to \(engine.displayName).")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicate(_ environment: WindowsEnvironment) async {
        var operation = StillOperation(kind: .duplicateEnvironment, environmentID: environment.id)
        do {
            try await withStoppedEnvironmentLease(operation) {
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
            }
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
            try await withStoppedEnvironmentLease(operation) {
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
            }
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

    func inspectBackup(at backupURL: URL, password: String?) async throws -> BackupManifest {
        try await backupService.inspectBackup(
            at: backupURL,
            password: password?.isEmpty == true ? nil : password
        )
    }

    func requestEnvironmentRemoval(_ environment: WindowsEnvironment) {
        pendingEnvironmentRemoval = environment
    }

    func confirmEnvironmentRemoval() async {
        guard let environment = pendingEnvironmentRemoval else { return }
        do {
            try await withStoppedEnvironmentLease(StillOperation(
                kind: .deleteEnvironment,
                environmentID: environment.id
            )) {
                try await store.deleteEnvironmentRecord(id: environment.id)
                pendingEnvironmentRemoval = nil
                await load()
                activityState = .success("\(environment.name) was removed from Still. Its files were not changed.")
            }
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
            try await withStoppedEnvironmentLease(StillOperation(
                kind: .deleteEnvironment,
                environmentID: environment.id
            )) {
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
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func withEnvironmentLease<T>(
        _ operation: StillOperation,
        perform work: () async throws -> T
    ) async throws -> T {
        try await environmentOperationCoordinator.begin(operation)
        do {
            let result = try await work()
            await environmentOperationCoordinator.finish(operation)
            return result
        } catch {
            await environmentOperationCoordinator.finish(operation)
            throw error
        }
    }

    private func withStoppedEnvironmentLease<T>(
        _ operation: StillOperation,
        perform work: () async throws -> T
    ) async throws -> T {
        try await withEnvironmentLease(operation) {
            let processSnapshots = try await Task.detached {
                try WineRuntimeProbe.runningProcesses(enrichWorkingDirectories: false)
            }.value
            let currentSessions = await supervisor.activeSessions()
            sessions = currentSessions
            try WineRuntimeProbe.requireStopped(
                environmentID: operation.environmentID,
                environments: environments,
                processes: processSnapshots,
                sessions: currentSessions
            )
            return try await work()
        }
    }

    private func terminateAllWineActivity(force: Bool) async throws {
        let initialProcesses = try await Task.detached {
            try WineRuntimeProbe.runningProcesses(enrichWorkingDirectories: false)
        }.value
        let initialLiveIDs = WineRuntimeProbe.liveEnvironmentIDs(
            in: initialProcesses,
            environments: environments
        )
        let representedEnvironmentIDs = Set(
            (await supervisor.activeSessions()).compactMap(\.environmentID)
        )
        let targetEnvironmentIDs = initialLiveIDs.union(representedEnvironmentIDs)
        if force {
            try await supervisor.forceStopAll()
        } else {
            try await supervisor.stopAll()
        }
        for environmentID in initialLiveIDs.subtracting(representedEnvironmentIDs) {
            guard let environment = environments.first(where: { $0.id == environmentID }) else {
                continue
            }
            let selectedEngine = try engine(for: environment)
            let sessionID = UUID()
            let plan = force
                ? WineCommandBuilder.forceStopPlan(
                    sessionID: sessionID,
                    engine: selectedEngine,
                    bottle: bottle(from: environment),
                    logURL: LogLocations.launchLogURL(sessionID: sessionID)
                )
                : WineCommandBuilder.stopPlan(
                    sessionID: sessionID,
                    engine: selectedEngine,
                    bottle: bottle(from: environment),
                    logURL: LogLocations.launchLogURL(sessionID: sessionID)
                )
            let exitCode = try await supervisor.runAndWait(plan)
            guard [0, 1].contains(exitCode) else {
                throw StillCoreError.processFailed(exitCode)
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let processes = try await Task.detached {
                try WineRuntimeProbe.runningProcesses(enrichWorkingDirectories: false)
            }.value
            let remaining = WineRuntimeProbe.liveEnvironmentIDs(
                in: processes,
                environments: environments
            ).intersection(targetEnvironmentIDs)
            if remaining.isEmpty {
                liveEnvironmentIDs.subtract(targetEnvironmentIDs)
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw StillCoreError.terminationFailed(
            targetEnvironmentIDs.map { "Environment \($0) is still running." }
        )
    }

    private func reconcileLiveWineSessions() async {
        do {
            let processSnapshots = try await Task.detached {
                try WineRuntimeProbe.runningProcesses()
            }.value
            liveEnvironmentIDs = WineRuntimeProbe.liveEnvironmentIDs(
                in: processSnapshots,
                environments: environments
            )
            let observations = WineRuntimeProbe.observeApplications(
                in: processSnapshots,
                environments: environments,
                applications: applications,
                launchEntries: launchEntries
            )
            let validationSnapshots = try await Task.detached {
                try WineRuntimeProbe.runningProcesses(enrichWorkingDirectories: false)
            }.value
            let validatedObservations = observations.filter { observation in
                return validationSnapshots.contains {
                    observation.processIdentity.matches($0)
                }
            }
            let activeApplicationIDs = Set(
                (await supervisor.activeSessions()).compactMap(\.applicationID)
            )
            for observation in validatedObservations
            where !activeApplicationIDs.contains(observation.applicationID) {
                guard let application = applications.first(where: {
                    $0.id == observation.applicationID
                }),
                let environment = environments.first(where: {
                    $0.id == observation.environmentID
                }),
                let entryID = application.launchEntryIDs.first,
                let entry = launchEntries.first(where: { $0.id == entryID }) else {
                    continue
                }
                let engine = try engine(for: environment)
                let sessionID = UUID()
                let plan = WineCommandBuilder.launchPlan(
                    sessionID: sessionID,
                    engine: engine,
                    request: LaunchRequest(
                        bottle: bottle(from: environment),
                        executableURL: entry.executableURL,
                        arguments: entry.arguments,
                        workingDirectoryURL: entry.workingDirectoryURL,
                        applicationID: application.id,
                        environmentID: environment.id
                    ),
                    logURL: LogLocations.launchLogURL(sessionID: sessionID)
                )
                _ = try await supervisor.adopt(
                    plan,
                    observedProcessIdentifier: observation.processIdentifier,
                    observedProcessName: observation.processName,
                    observedProcessStartedAt: observation.processIdentity.startedAt
                )
            }
            await supervisor.reconcileApplications(validatedObservations)
            sessions = await supervisor.activeSessions()
            reconcileWindowActivationNotice(
                activeApplicationIDs: Set(validatedObservations.map(\.applicationID))
                    .union(sessions.compactMap(\.applicationID))
            )
        } catch {
            sessions = await supervisor.activeSessions()
        }
    }

    private func waitForApplicationObservation(
        application: LibraryApplication,
        environment: WindowsEnvironment,
        timeout: TimeInterval
    ) async throws -> LiveWineApplicationObservation {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let processSnapshots = try await Task.detached {
                try WineRuntimeProbe.runningProcesses()
            }.value
            if let observation = WineRuntimeProbe.observeApplications(
                in: processSnapshots,
                environments: [environment],
                applications: [application],
                launchEntries: launchEntries.filter { $0.applicationID == application.id }
            ).first {
                return observation
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw StillCoreError.launchReadinessTimedOut(application.name)
    }

    private func openRunningApplication(_ application: LibraryApplication) async {
        do {
            let processSnapshots = try await Task.detached {
                try WineRuntimeProbe.runningProcesses()
            }.value
            guard let observation = WineRuntimeProbe.observeApplications(
                in: processSnapshots,
                environments: environments,
                applications: applications,
                launchEntries: launchEntries
            ).first(where: { $0.applicationID == application.id }) else {
                pendingWindowControlApplicationID = nil
                launchNotice = "\(application.name) is running in the background."
                return
            }
            switch windowActivator.activate(
                applicationName: application.name,
                processIdentities: observation.relatedProcessIdentities
            ) {
            case .activated:
                pendingWindowControlApplicationID = nil
                launchNotice = nil
                activityState = .success("\(application.name) opened.")
            case .accessibilityPermissionRequired:
                pendingWindowControlApplicationID = application.id
                launchNotice = "Still needs Window Control permission to focus \(application.name)."
            case .noWindow:
                pendingWindowControlApplicationID = nil
                launchNotice = "\(application.name) is running, but its window was not found."
            case .ambiguousWindow:
                pendingWindowControlApplicationID = nil
                launchNotice = "\(application.name) is running, but its window could not be identified safely."
            case .failed:
                pendingWindowControlApplicationID = nil
                launchNotice = "\(application.name) is running, but macOS did not activate its window."
            }
        } catch {
            pendingWindowControlApplicationID = nil
            launchNotice = "\(application.name) is running, but its window could not be focused."
        }
    }

    func requestWindowControlPermission() {
        windowActivator.requestAccessibilityPermission()
    }

    func retryWindowActivation() async {
        guard let applicationID = pendingWindowControlApplicationID,
              let application = applications.first(where: { $0.id == applicationID }) else {
            dismissLaunchNotice()
            return
        }
        await reconcileLiveWineSessions()
        guard runtimeState(for: application) == .running else {
            dismissLaunchNotice()
            return
        }
        await openRunningApplication(application)
    }

    func dismissLaunchNotice() {
        launchNotice = nil
        pendingWindowControlApplicationID = nil
    }

    func reconcileWindowActivationNotice(
        activeApplicationIDs: Set<LibraryApplication.ID>
    ) {
        guard let applicationID = pendingWindowControlApplicationID,
              !activeApplicationIDs.contains(applicationID) else {
            return
        }
        dismissLaunchNotice()
    }

    func reconcileVisibleApplicationSelection() {
        guard destination.isLibrary else { return }
        let visible = visibleApplications
        guard !visible.contains(where: { $0.id == selectedApplicationID }) else { return }
        selectedApplicationID = visible.first?.id
    }

    private func waitForApplicationSessionExit(
        applicationID: LibraryApplication.ID,
        timeout: TimeInterval = 15
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let activeSessions = await supervisor.activeSessions()
            sessions = activeSessions
            if !activeSessions.contains(where: { $0.applicationID == applicationID }) {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw StillCoreError.terminationFailed([
            "The application session did not finish after the stop request."
        ])
    }

    private func schedulePerformanceSampling(
        applicationID: LibraryApplication.ID,
        sessionID: LaunchSession.ID,
        operationID: StillOperation.ID,
        launchRequestedAt: Date
    ) {
        performanceSamplingTasks.removeValue(forKey: applicationID)?.cancel()
        performanceSamplingTasks[applicationID] = Task { [weak self] in
            var elapsed = 0
            for deadline in [2, 8, 20, 30] {
                let delay = deadline - elapsed
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                elapsed = deadline
                guard let self,
                      await self.supervisor.session(id: sessionID)?.state == .running else {
                    return
                }
                if await self.capturePerformance(
                    applicationID: applicationID,
                    operationID: operationID,
                    launchRequestedAt: launchRequestedAt
                ) { return }
            }
        }
    }

    private func capturePerformance(
        applicationID: LibraryApplication.ID,
        operationID: StillOperation.ID,
        launchRequestedAt: Date
    ) async -> Bool {
        guard let application = applications.first(where: { $0.id == applicationID }),
              let environment = environments.first(where: { $0.id == application.environmentID }),
              let entryID = application.launchEntryIDs.first,
              let entry = launchEntries.first(where: { $0.id == entryID }) else { return true }
        do {
            let processSnapshots = try await Task.detached {
                try WineRuntimeProbe.runningProcesses()
            }.value
            let snapshot = WineRuntimeProbe.performanceSnapshot(
                application: application,
                environment: environment,
                entry: entry,
                processes: processSnapshots,
                launchLatency: Date().timeIntervalSince(launchRequestedAt)
            )
            guard snapshot.processCount > 0 else { return false }
            performanceSnapshots[application.id] = snapshot
            if var operation = (try? await store.operations())?.first(where: {
                $0.id == operationID
            }) {
                operation.appendEvent(
                    String(
                        format: "Observed after %.1f s · CPU %.1f%% · Memory %.0f MB",
                        snapshot.launchLatency ?? 0,
                        snapshot.cpuPercent,
                        Double(snapshot.residentMemoryBytes) / 1_048_576
                    )
                )
                try? await store.saveOperation(operation)
                operations = (try? await store.operations()) ?? operations
            }
            return true
        } catch {
            return false
        }
    }

    private func launchFailureMessage(_ error: Error, applicationName: String) -> String {
        if case StillCoreError.duplicateLaunch = error {
            return "\(applicationName) is already launching or running."
        }
        return error.localizedDescription
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
            wineVersion: engine.wineVersion,
            dxmtRevision: engine.dxmtRevision,
            installURL: engine.wineBinaryURL.deletingLastPathComponent(),
            capabilities: engine.capabilities,
            manifestID: bundledManifest?.id,
            requiredLicenseID: bundledManifest?.distributionPolicy == .externalLicenseRequired
                ? bundledManifest?.id
                : nil,
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
            supportsRosetta: supportsRosetta,
            acceptedLicenseIDs: acceptedEngineLicenseIDs
        )
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
