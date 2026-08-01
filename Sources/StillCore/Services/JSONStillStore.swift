import Foundation

public actor JSONStillStore {
    public let rootURL: URL
    public let storeURL: URL
    public let legacyBottlesURL: URL
    public let legacyPinsURL: URL
    public let migrationBackupURL: URL

    private let fileManager: FileManager
    private let migrator: StillStoreMigrator

    public init(
        rootURL: URL = JSONBottleStore.defaultRootURL(),
        fileManager: FileManager = .default,
        migrator: StillStoreMigrator = StillStoreMigrator()
    ) {
        self.rootURL = rootURL
        self.storeURL = rootURL.appending(path: "store.json")
        self.legacyBottlesURL = rootURL.appending(path: "bottles.json")
        self.legacyPinsURL = rootURL.appending(path: "application-pins.json")
        self.migrationBackupURL = rootURL
            .appending(path: "Migration Backups", directoryHint: .isDirectory)
            .appending(path: "schema-1", directoryHint: .isDirectory)
        self.fileManager = fileManager
        self.migrator = migrator
    }

    public func load() throws -> StillStoreDocument {
        if fileManager.fileExists(atPath: storeURL.path) {
            let document = try decode(Data(contentsOf: storeURL))
            guard document.schemaVersion == StillStoreDocument.currentSchemaVersion else {
                throw StillCoreError.unsupportedSchema(document.schemaVersion)
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
        return document
    }

    public func save(_ document: StillStoreDocument) throws {
        guard document.schemaVersion == StillStoreDocument.currentSchemaVersion else {
            throw StillCoreError.unsupportedSchema(document.schemaVersion)
        }
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try encoder.encode(document).write(to: storeURL, options: .atomic)
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

    public func deleteEnvironmentRecord(id: WindowsEnvironment.ID) throws {
        var document = try load()
        let applicationIDs = Set(
            document.applications
                .filter { $0.environmentID == id }
                .map(\.id)
        )
        document.launchEntries.removeAll { applicationIDs.contains($0.applicationID) }
        document.applications.removeAll { applicationIDs.contains($0.id) }
        document.environments.removeAll { $0.id == id }
        try save(document)
    }

    public func removeApplicationFromLibrary(id: LibraryApplication.ID) throws {
        var document = try load()
        document.applications.removeAll { $0.id == id }
        document.launchEntries.removeAll { $0.applicationID == id }
        try save(document)
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
        guard Set(application.launchEntryIDs).isSubset(of: suppliedEntryIDs),
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
