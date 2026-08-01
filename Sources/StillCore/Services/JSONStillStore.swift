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
        document.operations.removeAll { $0.environmentID == id }
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
