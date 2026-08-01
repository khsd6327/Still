import Foundation

public actor EnvironmentRestoreCoordinator {
    public nonisolated let journalRootURL: URL
    public nonisolated let stagingRootURL: URL

    private let store: JSONStillStore
    private let backupService: BackupService
    private let ownershipService: EnvironmentOwnershipService
    private let fileManager: FileManager
    private let beforeStoreCommit: @Sendable () async throws -> Void

    public init(
        store: JSONStillStore,
        backupService: BackupService,
        ownershipService: EnvironmentOwnershipService,
        rootURL: URL,
        fileManager: FileManager = .default
    ) {
        self.init(
            store: store,
            backupService: backupService,
            ownershipService: ownershipService,
            rootURL: rootURL,
            fileManager: fileManager,
            beforeStoreCommit: {}
        )
    }

    init(
        store: JSONStillStore,
        backupService: BackupService,
        ownershipService: EnvironmentOwnershipService,
        rootURL: URL,
        fileManager: FileManager = .default,
        beforeStoreCommit: @escaping @Sendable () async throws -> Void
    ) {
        self.store = store
        self.backupService = backupService
        self.ownershipService = ownershipService
        self.journalRootURL = rootURL.appending(
            path: "Restore Journal",
            directoryHint: .isDirectory
        )
        self.stagingRootURL = rootURL.appending(
            path: "Restore Staging",
            directoryHint: .isDirectory
        )
        self.fileManager = fileManager
        self.beforeStoreCommit = beforeStoreCommit
    }

    @discardableResult
    public func restore(
        backupURL: URL,
        password: String? = nil,
        activeSessions: [LaunchSession] = []
    ) async throws -> WindowsEnvironment {
        let manifest = try await backupService.inspectBackup(
            at: backupURL,
            password: password
        )
        let document = try await store.load()
        try validateRequirements(manifest, in: document)

        let operationID = UUID()
        let environmentID = UUID()
        let managementNonce = UUID()
        let destinationPrefixURL = ownershipService.managedPrefixURL(
            for: environmentID
        )
        let stagingPrefixURL = expectedStagingURL(
            operationID: operationID,
            environmentID: environmentID
        )
        let restoredRecords = try makeRestoredRecords(
            manifest: manifest,
            environmentID: environmentID,
            managementNonce: managementNonce,
            destinationPrefixURL: destinationPrefixURL
        )
        var journal = EnvironmentRestoreJournal(
            id: operationID,
            storeIdentifier: document.storeIdentifier,
            environmentID: environmentID,
            managementNonce: managementNonce,
            stagingPrefixURL: stagingPrefixURL,
            destinationPrefixURL: destinationPrefixURL,
            applicationIDs: restoredRecords.applications.map(\.id),
            launchEntryIDs: restoredRecords.launchEntries.map(\.id)
        )
        try requireUnused(stagingPrefixURL)
        try requireUnused(destinationPrefixURL)
        try persist(journal)

        do {
            let restoredManifest = try await backupService.restore(
                backupURL: backupURL,
                destinationPrefixURL: stagingPrefixURL,
                password: password,
                activeSessions: activeSessions
            )
            guard restoredManifest == manifest else {
                throw StillCoreError.verificationFailed(
                    "The backup manifest changed during restore."
                )
            }
            try fileManager.createDirectory(
                at: destinationPrefixURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(
                at: stagingPrefixURL,
                to: destinationPrefixURL
            )
            journal.state = .prefixMaterialized
            journal.updatedAt = .now
            try persist(journal)
            try ownershipService.writeMarker(
                for: restoredRecords.environment,
                storeIdentifier: document.storeIdentifier
            )

            try await beforeStoreCommit()
            try await store.commitRestoredEnvironment(
                restoredRecords.environment,
                applications: restoredRecords.applications,
                launchEntries: restoredRecords.launchEntries,
                requiredEngineBuildID: manifest.requiredEngineBuildID,
                requiredComponents: manifest.requiredComponents,
                expectedStoreIdentifier: document.storeIdentifier
            )

            journal.state = .storeCommitted
            journal.updatedAt = .now
            try? persist(journal)
            try? removeJournal(journal.id)
            return restoredRecords.environment
        } catch let transactionError {
            if let committed = try? await store.environment(id: environmentID),
               committed == restoredRecords.environment {
                return restoredRecords.environment
            }
            do {
                try rollback(journal)
            } catch {
                throw StillCoreError.invalidStore(
                    "The restore transaction could not roll back its staged files."
                )
            }
            throw transactionError
        }
    }

    @discardableResult
    public func recoverInterruptedRestores() async throws -> Int {
        guard fileManager.fileExists(atPath: journalRootURL.path) else { return 0 }
        let document = try await store.load()
        let journalURLs = try fileManager.contentsOfDirectory(
            at: journalRootURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        var recoveredCount = 0

        for url in journalURLs {
            var journal = try JSONDecoder().decode(
                EnvironmentRestoreJournal.self,
                from: Data(contentsOf: url)
            )
            try validate(journal, storeIdentifier: document.storeIdentifier)
            if let environment = document.environments.first(where: {
                $0.id == journal.environmentID
            }) {
                try validateCommitted(journal, environment: environment, document: document)
                if fileManager.fileExists(atPath: journal.stagingPrefixURL.path) {
                    try removeTransactionDirectory(journal.stagingPrefixURL)
                }
                journal.state = .storeCommitted
            } else {
                if fileManager.fileExists(atPath: journal.destinationPrefixURL.path) {
                    try validateDestinationBeforeRollback(journal)
                    try removeTransactionDirectory(journal.destinationPrefixURL)
                }
                if fileManager.fileExists(atPath: journal.stagingPrefixURL.path) {
                    try removeTransactionDirectory(journal.stagingPrefixURL)
                }
                journal.state = .rolledBack
            }
            journal.updatedAt = .now
            try persist(journal)
            try removeJournal(journal.id)
            recoveredCount += 1
        }
        return recoveredCount
    }

    private func validateRequirements(
        _ manifest: BackupManifest,
        in document: StillStoreDocument
    ) throws {
        if let engineBuildID = manifest.requiredEngineBuildID,
           !document.engineBuilds.contains(where: { $0.id == engineBuildID }) {
            throw StillCoreError.engineNotFound(engineBuildID)
        }
        for (componentID, version) in manifest.requiredComponents {
            guard document.components.contains(where: {
                $0.id == componentID && $0.version == version
            }) else {
                throw StillCoreError.unavailableCapability(
                    componentID,
                    "Version \(version) is required by the backup."
                )
            }
        }
    }

    private func makeRestoredRecords(
        manifest: BackupManifest,
        environmentID: WindowsEnvironment.ID,
        managementNonce: UUID,
        destinationPrefixURL: URL
    ) throws -> (
        environment: WindowsEnvironment,
        applications: [LibraryApplication],
        launchEntries: [LaunchEntry]
    ) {
        let source = manifest.environment
        try validateSnapshot(manifest.snapshot, environment: source)
        let environment = WindowsEnvironment(
            id: environmentID,
            name: "\(source.name) Restored",
            prefixURL: destinationPrefixURL,
            pinnedEngineBuildID: manifest.requiredEngineBuildID,
            provisionedEngineBuildID: manifest.requiredEngineBuildID,
            profileID: manifest.snapshot.profileID,
            graphicsBackend: manifest.snapshot.graphicsBackend,
            windowsVersion: manifest.snapshot.windowsVersion,
            enhancedSync: manifest.snapshot.enhancedSync,
            metalHUDEnabled: source.metalHUDEnabled,
            metalTraceEnabled: source.metalTraceEnabled,
            ownership: .managed,
            managementNonce: managementNonce
        )
        var restoredApplications: [LibraryApplication] = []
        var restoredEntries: [LaunchEntry] = []

        for sourceApplication in manifest.snapshot.applications {
            let applicationID = StableID.derived(
                from: "restored:\(environmentID):\(sourceApplication.id)"
            )
            let sourceEntries = manifest.snapshot.launchEntries.filter {
                $0.applicationID == sourceApplication.id
            }
            let entries = try sourceEntries.map { sourceEntry in
                LaunchEntry(
                    id: StableID.derived(
                        from: "restored-launch:\(applicationID):\(sourceEntry.id)"
                    ),
                    applicationID: applicationID,
                    executableURL: try remap(
                        sourceEntry.executableURL,
                        from: source.prefixURL,
                        to: destinationPrefixURL
                    ),
                    arguments: sourceEntry.arguments,
                    workingDirectoryURL: try sourceEntry.workingDirectoryURL.map {
                        try remap(
                            $0,
                            from: source.prefixURL,
                            to: destinationPrefixURL
                        )
                    }
                )
            }
            let application = LibraryApplication(
                id: applicationID,
                environmentID: environmentID,
                name: sourceApplication.name,
                category: sourceApplication.category,
                providerID: sourceApplication.providerID,
                providerItemID: sourceApplication.providerItemID,
                launchEntryIDs: entries.map(\.id),
                selectedProfileID: sourceApplication.selectedProfileID,
                isFavorite: sourceApplication.isFavorite,
                isHidden: sourceApplication.isHidden,
                providerManagedState: sourceApplication.providerManagedState
            )
            restoredApplications.append(application)
            restoredEntries.append(contentsOf: entries)
        }
        return (environment, restoredApplications, restoredEntries)
    }

    private func validateSnapshot(
        _ snapshot: ConfigurationSnapshot,
        environment: WindowsEnvironment
    ) throws {
        let applicationIDs = snapshot.applications.map(\.id)
        let entryIDs = snapshot.launchEntries.map(\.id)
        guard snapshot.environmentID == environment.id,
              snapshot.engineBuildID == environment.pinnedEngineBuildID,
              Set(applicationIDs).count == applicationIDs.count,
              Set(entryIDs).count == entryIDs.count,
              snapshot.applications.allSatisfy({
                  $0.environmentID == environment.id
              }) else {
            throw StillCoreError.invalidStore(
                "The backup configuration snapshot is inconsistent."
            )
        }
        let applicationIDSet = Set(applicationIDs)
        guard snapshot.launchEntries.allSatisfy({
            applicationIDSet.contains($0.applicationID)
        }) else {
            throw StillCoreError.invalidStore(
                "The backup contains an orphaned Launch Entry."
            )
        }
        for application in snapshot.applications {
            let storedEntryIDs = Set(
                snapshot.launchEntries
                    .filter { $0.applicationID == application.id }
                    .map(\.id)
            )
            guard Set(application.launchEntryIDs) == storedEntryIDs,
                  application.launchEntryIDs.count == storedEntryIDs.count else {
                throw StillCoreError.invalidStore(
                    "The backup contains inconsistent application relationships."
                )
            }
        }
    }

    private func remap(_ url: URL, from sourceRoot: URL, to destinationRoot: URL) throws -> URL {
        guard sourceRoot.isFileURL, url.isFileURL else {
            throw StillCoreError.unsafeArchivePath(url.absoluteString)
        }
        let sourcePath = sourceRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == sourcePath || path.hasPrefix(sourcePath + "/") else {
            throw StillCoreError.unsafeArchivePath(path)
        }
        let relativePath = String(path.dropFirst(sourcePath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relativePath.isEmpty
            ? destinationRoot
            : destinationRoot.appending(path: relativePath)
    }

    private func rollback(_ journal: EnvironmentRestoreJournal) throws {
        if fileManager.fileExists(atPath: journal.destinationPrefixURL.path) {
            try validateDestinationBeforeRollback(journal)
            try removeTransactionDirectory(journal.destinationPrefixURL)
        }
        if fileManager.fileExists(atPath: journal.stagingPrefixURL.path) {
            try removeTransactionDirectory(journal.stagingPrefixURL)
        }
        var rolledBack = journal
        rolledBack.state = .rolledBack
        rolledBack.updatedAt = .now
        try persist(rolledBack)
        try removeJournal(journal.id)
    }

    private func validateCommitted(
        _ journal: EnvironmentRestoreJournal,
        environment: WindowsEnvironment,
        document: StillStoreDocument
    ) throws {
        guard environment.ownership == .managed,
              environment.managementNonce == journal.managementNonce,
              environment.prefixURL.standardizedFileURL.path
                == journal.destinationPrefixURL.standardizedFileURL.path else {
            throw StillCoreError.invalidStore(
                "The restored Environment does not match its restore journal."
            )
        }
        let storedApplicationIDs = Set(
            document.applications
                .filter { $0.environmentID == journal.environmentID }
                .map(\.id)
        )
        let storedEntryIDs = Set(
            document.launchEntries
                .filter { storedApplicationIDs.contains($0.applicationID) }
                .map(\.id)
        )
        guard Set(journal.applicationIDs).isSubset(of: storedApplicationIDs),
              Set(journal.launchEntryIDs).isSubset(of: storedEntryIDs) else {
            throw StillCoreError.invalidStore(
                "The restored Library relationships are incomplete."
            )
        }
        try ownershipService.validateManagedOwnership(
            of: environment,
            storeIdentifier: journal.storeIdentifier
        )
    }

    private func validateDestinationBeforeRollback(
        _ journal: EnvironmentRestoreJournal
    ) throws {
        let markerURL = journal.destinationPrefixURL.appending(
            path: EnvironmentOwnershipService.markerFilename
        )
        if fileManager.fileExists(atPath: markerURL.path) {
            try ownershipService.validateManagedMarker(
                at: journal.destinationPrefixURL,
                environmentID: journal.environmentID,
                storeIdentifier: journal.storeIdentifier,
                nonce: journal.managementNonce
            )
        } else {
            try requireRealDirectory(journal.destinationPrefixURL)
        }
    }

    private func validate(
        _ journal: EnvironmentRestoreJournal,
        storeIdentifier: UUID
    ) throws {
        var mismatches: [String] = []
        if journal.version != EnvironmentRestoreJournal.currentVersion {
            mismatches.append("version")
        }
        if journal.storeIdentifier != storeIdentifier {
            mismatches.append("store identifier")
        }
        if journal.destinationPrefixURL.standardizedFileURL.path
            != ownershipService.managedPrefixURL(
                for: journal.environmentID
            ).standardizedFileURL.path {
            mismatches.append("destination path")
        }
        if journal.stagingPrefixURL.standardizedFileURL.path
            != expectedStagingURL(
                operationID: journal.id,
                environmentID: journal.environmentID
            ).standardizedFileURL.path {
            mismatches.append("staging path")
        }
        if Set(journal.applicationIDs).count != journal.applicationIDs.count {
            mismatches.append("application identifiers")
        }
        if Set(journal.launchEntryIDs).count != journal.launchEntryIDs.count {
            mismatches.append("Launch Entry identifiers")
        }
        guard mismatches.isEmpty else {
            throw StillCoreError.invalidStore(
                "The restore journal does not match this Still store: \(mismatches.joined(separator: ", "))."
            )
        }
    }

    private func requireUnused(_ url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            throw StillCoreError.invalidStore(
                "The restore destination already exists: \(url.path)"
            )
        }
    }

    private func requireRealDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw StillCoreError.invalidStore(
                "A restore transaction path is not a real directory."
            )
        }
    }

    private func removeTransactionDirectory(_ url: URL) throws {
        try requireRealDirectory(url)
        try fileManager.removeItem(at: url)
    }

    private func expectedStagingURL(
        operationID: UUID,
        environmentID: WindowsEnvironment.ID
    ) -> URL {
        stagingRootURL.appending(
            path: "\(operationID.uuidString)-\(environmentID.uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func persist(_ journal: EnvironmentRestoreJournal) throws {
        try fileManager.createDirectory(
            at: journalRootURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(
            to: journalURL(journal.id),
            options: .atomic
        )
    }

    private func removeJournal(_ id: UUID) throws {
        let url = journalURL(id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func journalURL(_ id: UUID) -> URL {
        journalRootURL.appending(path: "\(id.uuidString).json")
    }
}
