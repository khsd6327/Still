import CryptoKit
import Darwin
import Foundation

public actor JSONStillStore {
    public let rootURL: URL
    public let storeURL: URL
    public let legacyBottlesURL: URL
    public let legacyPinsURL: URL
    public let migrationBackupURL: URL
    public let lockURL: URL
    public let corruptStoresURL: URL

    private let fileManager: FileManager
    private let migrator: StillStoreMigrator
    private let validator: StillStoreValidator

    public init(
        rootURL: URL = JSONStillStore.defaultRootURL(),
        fileManager: FileManager = .default,
        migrator: StillStoreMigrator = StillStoreMigrator(),
        validator: StillStoreValidator = StillStoreValidator()
    ) {
        self.rootURL = rootURL
        self.storeURL = rootURL.appending(path: "store.json")
        self.legacyBottlesURL = rootURL.appending(path: "bottles.json")
        self.legacyPinsURL = rootURL.appending(path: "application-pins.json")
        self.migrationBackupURL = rootURL
            .appending(path: "Migration Backups", directoryHint: .isDirectory)
            .appending(path: "schema-1", directoryHint: .isDirectory)
        self.lockURL = rootURL.appending(path: ".store.lock")
        self.corruptStoresURL = rootURL.appending(
            path: "Corrupt Stores",
            directoryHint: .isDirectory
        )
        self.fileManager = fileManager
        self.migrator = migrator
        self.validator = validator
    }

    public static func defaultRootURL() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(
            path: ProductIdentity.bundleIdentifier,
            directoryHint: .isDirectory
        )
    }

    public func load() throws -> StillStoreDocument {
        if fileManager.fileExists(atPath: storeURL.path) {
            let data = try Data(contentsOf: storeURL)
            let document: StillStoreDocument
            do {
                document = try decode(data)
                try validator.validate(document)
            } catch let error as StillCoreError {
                if case .unsupportedSchema = error { throw error }
                try preserveCorruptStore(data)
                throw error
            } catch {
                try preserveCorruptStore(data)
                throw StillCoreError.invalidStore(
                    "The current store could not be decoded. The original bytes were preserved for recovery."
                )
            }
            guard document.schemaVersion == StillStoreDocument.currentSchemaVersion else {
                throw StillCoreError.unsupportedSchema(document.schemaVersion)
            }
            if try !containsStoreIdentifier(data) {
                do {
                    try save(document)
                } catch StillCoreError.concurrentStoreModification {
                    return try load()
                }
                return try load()
            }
            return document
        }

        let bottlesData = try dataIfPresent(at: legacyBottlesURL)
        let pinsData = try dataIfPresent(at: legacyPinsURL)
        let document = try migrator.migrate(
            bottlesData: bottlesData,
            pinsData: pinsData
        )

        if bottlesData != nil || pinsData != nil {
            try backUpLegacyFiles()
        }
        try save(document)
        return try load()
    }

    private func containsStoreIdentifier(_ data: Data) throws -> Bool {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StillCoreError.invalidStore("The current store is not a JSON object.")
        }
        return object["storeIdentifier"] != nil
    }

    public func save(_ document: StillStoreDocument) throws {
        guard document.schemaVersion == StillStoreDocument.currentSchemaVersion else {
            throw StillCoreError.unsupportedSchema(document.schemaVersion)
        }
        try validator.validate(document)
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try withStoreLock {
            let actualRevision: UInt64
            if fileManager.fileExists(atPath: storeURL.path) {
                let currentData = try Data(contentsOf: storeURL)
                do {
                    let current = try decode(currentData)
                    try validator.validate(current)
                    actualRevision = current.revision
                } catch {
                    try preserveCorruptStore(currentData)
                    throw error
                }
            } else {
                actualRevision = 0
            }
            guard document.revision == actualRevision else {
                throw StillCoreError.concurrentStoreModification(
                    expected: document.revision,
                    actual: actualRevision
                )
            }
            var next = document
            next.revision = actualRevision + 1
            try encoder.encode(next).write(to: storeURL, options: .atomic)
        }
    }

    public func environments() throws -> [WindowsEnvironment] {
        try load().environments.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func environment(
        id: WindowsEnvironment.ID
    ) throws -> WindowsEnvironment? {
        try load().environments.first { $0.id == id }
    }

    public func saveEnvironment(_ environment: WindowsEnvironment) throws {
        var document = try load()
        if let index = document.environments.firstIndex(
            where: { $0.id == environment.id }
        ) {
            if document.environments[index].pinnedEngineBuildID
                != environment.pinnedEngineBuildID {
                throw StillCoreError.engineChangeRequirementsNotMet(
                    "Use the guarded engine-change operation."
                )
            }
            document.environments[index] = environment
        } else {
            document.environments.append(environment)
        }
        try save(document)
    }

    public func synchronizeInstalledEngineBuilds(_ builds: [EngineBuild]) throws {
        guard !builds.isEmpty else { return }
        var document = try load()
        var changed = false
        for build in builds {
            if let index = document.engineBuilds.firstIndex(where: { $0.id == build.id }) {
                let stored = document.engineBuilds[index]
                guard stored != build else { continue }
                if stored.sourceArchiveSHA256 != nil
                    || stored.artifactManifestSHA256 != nil {
                    guard stored.family == build.family,
                          stored.version == build.version,
                          stored.installURL == build.installURL,
                          stored.capabilities == build.capabilities,
                          stored.sourceArchiveSHA256 == build.sourceArchiveSHA256,
                          stored.artifactManifestSHA256
                            == build.artifactManifestSHA256 else {
                        throw StillCoreError.verificationFailed(
                            "Installed engine '\(build.id)' no longer matches its recorded build."
                        )
                    }
                }
                document.engineBuilds[index] = build
            } else {
                document.engineBuilds.append(build)
            }
            changed = true
        }
        if changed {
            try save(document)
        }
    }

    public func updatePinnedEngine(
        environmentID: WindowsEnvironment.ID,
        engineBuildID: EngineBuild.ID,
        activeSessions: [LaunchSession],
        userApproved: Bool,
        restorePointCreated: Bool
    ) throws {
        var document = try load()
        guard let index = document.environments.firstIndex(
            where: { $0.id == environmentID }
        ) else {
            throw StillCoreError.invalidStore("Environment '\(environmentID)' was not found.")
        }
        guard document.engineBuilds.contains(where: { $0.id == engineBuildID }) else {
            throw StillCoreError.engineNotFound(engineBuildID)
        }
        guard !activeSessions.contains(where: {
            $0.environmentID == environmentID && $0.state.isActive
        }) else {
            throw StillCoreError.engineChangeRequirementsNotMet(
                "Stop every Launch Session in this Environment first."
            )
        }
        guard userApproved else {
            throw StillCoreError.engineChangeRequirementsNotMet(
                "Explicit approval is required."
            )
        }
        guard restorePointCreated else {
            throw StillCoreError.engineChangeRequirementsNotMet(
                "Create a Restore Point first."
            )
        }
        document.environments[index].pinnedEngineBuildID = engineBuildID
        document.environments[index].updatedAt = .now
        try save(document)
    }

    public func commitManagedRuntimeReplacement(
        environment replacement: WindowsEnvironment,
        expectedSourcePrefixURL: URL,
        activeSessions: [LaunchSession],
        userApproved: Bool,
        sourcePrefixRetained: Bool
    ) throws {
        var document = try load()
        guard let index = document.environments.firstIndex(
            where: { $0.id == replacement.id }
        ) else {
            throw StillCoreError.invalidStore("Environment '\(replacement.id)' was not found.")
        }
        let current = document.environments[index]
        guard current.prefixURL.standardizedFileURL.path
            == expectedSourcePrefixURL.standardizedFileURL.path else {
            throw StillCoreError.invalidStore(
                "The Environment source path changed before runtime replacement."
            )
        }
        guard replacement.ownership == .managed,
              replacement.managementNonce != nil,
              let engineBuildID = replacement.pinnedEngineBuildID,
              replacement.provisionedEngineBuildID == engineBuildID,
              document.engineBuilds.contains(where: { $0.id == engineBuildID }) else {
            throw StillCoreError.engineChangeRequirementsNotMet(
                "The replacement must use a registered engine and verified managed ownership."
            )
        }
        guard !activeSessions.contains(where: {
            $0.environmentID == replacement.id && $0.state.isActive
        }) else {
            throw StillCoreError.environmentMustBeStopped(replacement.id)
        }
        guard userApproved else {
            throw StillCoreError.engineChangeRequirementsNotMet(
                "Explicit approval is required."
            )
        }
        guard sourcePrefixRetained else {
            throw StillCoreError.engineChangeRequirementsNotMet(
                "Retain the source prefix as the rollback copy."
            )
        }

        document.environments[index] = replacement
        document.launchEntries = document.launchEntries.map { entry in
            var replacementEntry = entry
            replacementEntry.executableURL = remap(
                entry.executableURL,
                from: current.prefixURL,
                to: replacement.prefixURL
            )
            if let workingDirectoryURL = entry.workingDirectoryURL {
                replacementEntry.workingDirectoryURL = remap(
                    workingDirectoryURL,
                    from: current.prefixURL,
                    to: replacement.prefixURL
                )
            }
            return replacementEntry
        }
        try save(document)
    }

    public func deleteEnvironmentRecord(id: WindowsEnvironment.ID) throws {
        var document = try load()
        removeEnvironmentRecord(id: id, from: &document)
        try save(document)
    }

    public func commitManagedEnvironmentDeletion(
        id: WindowsEnvironment.ID,
        expectedPrefixURL: URL,
        expectedManagementNonce: UUID
    ) throws {
        var document = try load()
        guard let environment = document.environments.first(where: { $0.id == id }),
              environment.ownership == .managed,
              environment.prefixURL.standardizedFileURL
                == expectedPrefixURL.standardizedFileURL,
              environment.managementNonce == expectedManagementNonce else {
            throw StillCoreError.invalidStore(
                "The managed Environment changed while deletion was being committed."
            )
        }
        removeEnvironmentRecord(id: id, from: &document)
        try save(document)
    }

    private func removeEnvironmentRecord(
        id: WindowsEnvironment.ID,
        from document: inout StillStoreDocument
    ) {
        let applicationIDs = Set(
            document.applications
                .filter { $0.environmentID == id }
                .map(\.id)
        )
        document.launchEntries.removeAll { applicationIDs.contains($0.applicationID) }
        document.applications.removeAll { applicationIDs.contains($0.id) }
        document.operations.removeAll { $0.environmentID == id }
        document.environments.removeAll { $0.id == id }
    }

    private func remap(_ url: URL, from sourceRoot: URL, to destinationRoot: URL) -> URL {
        let sourcePath = sourceRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == sourcePath || path.hasPrefix(sourcePath + "/") else { return url }
        let relative = String(path.dropFirst(sourcePath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? destinationRoot : destinationRoot.appending(path: relative)
    }

    public func removeApplicationFromLibrary(id: LibraryApplication.ID) throws {
        var document = try load()
        document.applications.removeAll { $0.id == id }
        document.launchEntries.removeAll { $0.applicationID == id }
        try save(document)
    }

    @discardableResult
    public func reconcileDiscoveredApplications(
        environmentID: WindowsEnvironment.ID,
        providerID: String,
        discoveredProviderItemIDs: Set<String>
    ) throws -> [LibraryApplication.ID] {
        var document = try load()
        guard document.environments.contains(where: { $0.id == environmentID }) else {
            throw StillCoreError.invalidStore(
                "Cannot reconcile applications for missing Environment '\(environmentID)'."
            )
        }
        let staleIDs: Set<LibraryApplication.ID> = Set(
            document.applications.compactMap { application -> LibraryApplication.ID? in
            guard application.environmentID == environmentID,
                  application.providerID == providerID,
                  let itemID = application.providerItemID,
                  !discoveredProviderItemIDs.contains(itemID) else {
                return nil
            }
            return application.id
        })
        guard !staleIDs.isEmpty else { return [] }
        document.applications.removeAll { staleIDs.contains($0.id) }
        document.launchEntries.removeAll { staleIDs.contains($0.applicationID) }
        try save(document)
        return staleIDs.sorted { $0.uuidString < $1.uuidString }
    }

    public func applications(
        environmentID: WindowsEnvironment.ID? = nil
    ) throws -> [LibraryApplication] {
        let applications = try load().applications
        return applications
            .filter { environmentID == nil || $0.environmentID == environmentID }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    public func saveApplication(
        _ application: LibraryApplication,
        launchEntries: [LaunchEntry]
    ) throws {
        var document = try load()
        guard document.environments.contains(
            where: { $0.id == application.environmentID }
        ) else {
            throw StillCoreError.invalidStore(
                "Application '\(application.id)' refers to missing Environment '\(application.environmentID)'."
            )
        }
        let suppliedEntryIDs = Set(launchEntries.map(\.id))
        guard Set(application.launchEntryIDs) == suppliedEntryIDs,
              application.launchEntryIDs.count == suppliedEntryIDs.count,
              launchEntries.allSatisfy({ $0.applicationID == application.id }) else {
            throw StillCoreError.invalidStore(
                "Application '\(application.id)' has inconsistent launch entries."
            )
        }

        if let index = document.applications.firstIndex(
            where: { $0.id == application.id }
        ) {
            document.applications[index] = application
        } else {
            document.applications.append(application)
        }
        document.launchEntries.removeAll { $0.applicationID == application.id }
        document.launchEntries.append(contentsOf: launchEntries)
        try save(document)
    }

    public func commitRestorePoint(
        environment restoredEnvironment: WindowsEnvironment,
        applications restoredApplications: [LibraryApplication],
        launchEntries restoredLaunchEntries: [LaunchEntry],
        expectedEnvironment: WindowsEnvironment,
        expectedStoreIdentifier: UUID
    ) throws {
        var document = try load()
        guard document.storeIdentifier == expectedStoreIdentifier else {
            throw StillCoreError.invalidStore(
                "The Restore Point transaction belongs to a different Still store."
            )
        }
        guard let environmentIndex = document.environments.firstIndex(
            where: { $0.id == expectedEnvironment.id }
        ), document.environments[environmentIndex] == expectedEnvironment else {
            throw StillCoreError.invalidStore(
                "The Environment changed while its Restore Point was being restored."
            )
        }
        guard restoredEnvironment.id == expectedEnvironment.id,
              restoredEnvironment.prefixURL.standardizedFileURL
                == expectedEnvironment.prefixURL.standardizedFileURL,
              restoredEnvironment.ownership == expectedEnvironment.ownership,
              restoredEnvironment.managementNonce == expectedEnvironment.managementNonce else {
            throw StillCoreError.invalidStore(
                "A Restore Point cannot change Environment identity or ownership."
            )
        }
        if let engineBuildID = restoredEnvironment.pinnedEngineBuildID,
           !document.engineBuilds.contains(where: { $0.id == engineBuildID }) {
            throw StillCoreError.engineNotFound(engineBuildID)
        }
        guard restoredApplications.allSatisfy({
            $0.environmentID == restoredEnvironment.id
        }) else {
            throw StillCoreError.invalidStore(
                "The restored applications do not belong to the Environment."
            )
        }
        let restoredApplicationIDs = Set(restoredApplications.map(\.id))
        guard restoredApplicationIDs.count == restoredApplications.count,
              restoredLaunchEntries.allSatisfy({
                  restoredApplicationIDs.contains($0.applicationID)
              }),
              Set(restoredLaunchEntries.map(\.id)).count == restoredLaunchEntries.count else {
            throw StillCoreError.invalidStore(
                "The restored application relationships are inconsistent."
            )
        }
        let currentApplicationIDs = Set(document.applications.lazy
            .filter { $0.environmentID == restoredEnvironment.id }
            .map(\.id))
        let otherApplicationIDs = Set(document.applications.lazy
            .filter { $0.environmentID != restoredEnvironment.id }
            .map(\.id))
        let currentEntryIDs = Set(document.launchEntries.lazy
            .filter { currentApplicationIDs.contains($0.applicationID) }
            .map(\.id))
        let otherEntryIDs = Set(document.launchEntries.lazy
            .filter { !currentEntryIDs.contains($0.id) }
            .map(\.id))
        guard restoredApplicationIDs.isDisjoint(with: otherApplicationIDs),
              Set(restoredLaunchEntries.map(\.id)).isDisjoint(with: otherEntryIDs) else {
            throw StillCoreError.invalidStore(
                "The restored records conflict with another Environment."
            )
        }

        document.environments[environmentIndex] = restoredEnvironment
        document.applications.removeAll { $0.environmentID == restoredEnvironment.id }
        document.launchEntries.removeAll { currentApplicationIDs.contains($0.applicationID) }
        document.applications.append(contentsOf: restoredApplications)
        document.launchEntries.append(contentsOf: restoredLaunchEntries)
        try save(document)
    }

    public func commitRestoredEnvironment(
        _ environment: WindowsEnvironment,
        applications: [LibraryApplication],
        launchEntries: [LaunchEntry],
        requiredEngineBuildID: EngineBuild.ID?,
        requiredComponents: [RuntimeComponent.ID: String],
        expectedStoreIdentifier: UUID
    ) throws {
        var document = try load()
        guard document.storeIdentifier == expectedStoreIdentifier else {
            throw StillCoreError.invalidStore(
                "The restore transaction belongs to a different Still store."
            )
        }
        guard !document.environments.contains(where: { $0.id == environment.id }) else {
            throw StillCoreError.invalidStore(
                "Environment '\(environment.id)' already exists."
            )
        }
        guard applications.allSatisfy({ $0.environmentID == environment.id }) else {
            throw StillCoreError.invalidStore(
                "The restored applications do not belong to the restored Environment."
            )
        }
        let applicationIDs = Set(applications.map(\.id))
        guard applicationIDs.count == applications.count,
              launchEntries.allSatisfy({ applicationIDs.contains($0.applicationID) }) else {
            throw StillCoreError.invalidStore(
                "The restored application relationships are inconsistent."
            )
        }
        let newEntryIDs = Set(launchEntries.map(\.id))
        guard newEntryIDs.count == launchEntries.count,
              document.applications.allSatisfy({ !applicationIDs.contains($0.id) }),
              document.launchEntries.allSatisfy({ !newEntryIDs.contains($0.id) }) else {
            throw StillCoreError.invalidStore(
                "The restored records conflict with existing Library records."
            )
        }
        if let requiredEngineBuildID,
           !document.engineBuilds.contains(where: { $0.id == requiredEngineBuildID }) {
            throw StillCoreError.engineNotFound(requiredEngineBuildID)
        }
        for (componentID, requiredVersion) in requiredComponents {
            guard document.components.contains(where: {
                $0.id == componentID && $0.version == requiredVersion
            }) else {
                throw StillCoreError.unavailableCapability(
                    componentID,
                    "Version \(requiredVersion) is required by the backup."
                )
            }
        }

        document.environments.append(environment)
        document.applications.append(contentsOf: applications)
        document.launchEntries.append(contentsOf: launchEntries)
        try save(document)
    }

    public func operations(
        environmentID: WindowsEnvironment.ID? = nil
    ) throws -> [StillOperation] {
        try load().operations
            .filter { environmentID == nil || $0.environmentID == environmentID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func saveOperation(_ operation: StillOperation) throws {
        var document = try load()
        guard document.environments.contains(where: { $0.id == operation.environmentID }) else {
            throw StillCoreError.invalidStore(
                "Operation '\(operation.id)' refers to missing Environment '\(operation.environmentID)'."
            )
        }
        if let index = document.operations.firstIndex(where: { $0.id == operation.id }) {
            document.operations[index] = operation
        } else {
            document.operations.append(operation)
        }
        try save(document)
    }

    @discardableResult
    public func recoverInterruptedOperations(at date: Date = .now) throws -> [StillOperation] {
        var document = try load()
        var recovered: [StillOperation] = []
        for index in document.operations.indices
        where !document.operations[index].state.isTerminal {
            var operation = document.operations[index]
            if operation.state == .pending {
                try operation.transition(to: .cancelled, at: date, resultSummary: "Interrupted before starting.")
            } else {
                if operation.state == .running {
                    try operation.transition(to: .failed, at: date, resultSummary: "Interrupted when Still previously exited.")
                } else {
                    try operation.transition(to: .failed, at: date, resultSummary: "Cancellation was interrupted when Still previously exited.")
                }
            }
            document.operations[index] = operation
            recovered.append(operation)
        }
        if !recovered.isEmpty { try save(document) }
        return recovered
    }

    private func dataIfPresent(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func backUpLegacyFiles() throws {
        try fileManager.createDirectory(
            at: migrationBackupURL,
            withIntermediateDirectories: true
        )
        try copyIfNeeded(
            legacyBottlesURL,
            to: migrationBackupURL.appending(path: "bottles.json")
        )
        try copyIfNeeded(
            legacyPinsURL,
            to: migrationBackupURL.appending(path: "application-pins.json")
        )
    }

    private func copyIfNeeded(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path) else {
            return
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func preserveCorruptStore(_ data: Data) throws {
        try fileManager.createDirectory(
            at: corruptStoresURL,
            withIntermediateDirectories: true
        )
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let destination = corruptStoresURL.appending(
            path: "store-\(digest.prefix(16)).json"
        )
        if !fileManager.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
    }

    private func withStoreLock<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw StillCoreError.invalidStore("The store lock could not be opened.")
        }
        defer { Darwin.close(descriptor) }
        var fileLock = Darwin.flock()
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLKW, &fileLock) != -1 else {
            throw StillCoreError.invalidStore("The store lock could not be acquired.")
        }
        defer {
            fileLock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
        }
        return try operation()
    }

    private func decode(_ data: Data) throws -> StillStoreDocument {
        try decoder.decode(StillStoreDocument.self, from: data)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(
                String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
            )
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let encoded = try container.decode(String.self)
            guard let bitPattern = UInt64(encoded, radix: 16) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid Still date bit pattern."
                )
            }
            return Date(
                timeIntervalSinceReferenceDate: TimeInterval(bitPattern: bitPattern)
            )
        }
        return decoder
    }
}
