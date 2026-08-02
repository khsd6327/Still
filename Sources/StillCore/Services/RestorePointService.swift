import Foundation

public actor RestorePointService {
    public let rootURL: URL
    private let fileManager: FileManager

    public init(
        rootURL: URL = JSONBottleStore.defaultRootURL()
            .appending(path: "Restore Points", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func create(
        environment: WindowsEnvironment,
        applications: [LibraryApplication],
        launchEntries: [LaunchEntry],
        activeSessions: [LaunchSession],
        limit: Int = 5
    ) throws -> RestorePointManifest {
        try requireStopped(environment.id, sessions: activeSessions)
        let existing = try manifests(environmentID: environment.id)
        guard existing.count < limit else {
            throw StillCoreError.restorePointLimitReached(limit)
        }
        guard fileManager.fileExists(atPath: environment.prefixURL.path) else {
            throw StillCoreError.invalidStore("Environment files are missing.")
        }

        let id = UUID()
        let pointURL = rootURL
            .appending(path: environment.id.uuidString, directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
        let prefixURL = pointURL.appending(path: "Prefix", directoryHint: .isDirectory)
        do {
            let usedClone = try FileTreeServices.verifiedCopy(
                from: environment.prefixURL,
                to: prefixURL
            )
            let entries = try FileTreeServices.entries(at: prefixURL)
            let snapshot = ConfigurationSnapshot(
                environment: environment,
                applications: applications,
                launchEntries: launchEntries
            )
            let manifest = RestorePointManifest(
                id: id,
                environmentID: environment.id,
                environmentName: environment.name,
                createdAt: .now,
                snapshot: snapshot,
                requiredEngineBuildID: environment.pinnedEngineBuildID,
                affectedApplicationIDs: snapshot.applications.map(\.id),
                fileCount: entries.count,
                byteCount: entries.reduce(0) { $0 + $1.byteCount },
                usedCloneCopy: usedClone,
                isProtected: false
            )
            try encoder.encode(manifest).write(
                to: pointURL.appending(path: "manifest.json"),
                options: .atomic
            )
            return manifest
        } catch {
            if fileManager.fileExists(atPath: pointURL.path) {
                try? fileManager.removeItem(at: pointURL)
            }
            throw error
        }
    }

    public func manifests(
        environmentID: WindowsEnvironment.ID
    ) throws -> [RestorePointManifest] {
        let environmentRoot = rootURL.appending(path: environmentID.uuidString)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: environmentRoot,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return try urls.compactMap { url in
            let manifestURL = url.appending(path: "manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
            return try decoder.decode(
                RestorePointManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func previewRestore(id: UUID, environmentID: UUID) throws -> RestorePointManifest {
        guard let manifest = try manifests(environmentID: environmentID).first(
            where: { $0.id == id }
        ) else {
            throw StillCoreError.invalidStore("Restore Point '\(id)' was not found.")
        }
        return manifest
    }

    public func restore(
        id: UUID,
        environment: WindowsEnvironment,
        activeSessions: [LaunchSession],
        store: JSONStillStore
    ) async throws -> RestorePointManifest {
        try requireStopped(environment.id, sessions: activeSessions)
        let manifest = try previewRestore(id: id, environmentID: environment.id)
        guard manifest.snapshot.environmentID == environment.id else {
            throw StillCoreError.invalidStore(
                "The Restore Point belongs to a different Environment."
            )
        }

        let document = try await store.load()
        guard document.environments.first(where: { $0.id == environment.id }) == environment else {
            throw StillCoreError.invalidStore(
                "The Environment changed before its Restore Point could be restored."
            )
        }
        if let requiredEngineBuildID = manifest.requiredEngineBuildID,
           !document.engineBuilds.contains(where: { $0.id == requiredEngineBuildID }) {
            throw StillCoreError.engineNotFound(requiredEngineBuildID)
        }

        let pointPrefixURL = rootURL
            .appending(path: environment.id.uuidString, directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
            .appending(path: "Prefix", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: pointPrefixURL.path),
              fileManager.fileExists(atPath: environment.prefixURL.path) else {
            throw StillCoreError.invalidStore("Restore Point files are missing.")
        }

        let parentURL = environment.prefixURL.deletingLastPathComponent()
        let transactionID = UUID().uuidString
        let stagingURL = parentURL.appending(
            path: ".still-restore-staging-\(transactionID)",
            directoryHint: .isDirectory
        )
        let rollbackURL = parentURL.appending(
            path: ".still-restore-rollback-\(transactionID)",
            directoryHint: .isDirectory
        )
        _ = try FileTreeServices.verifiedCopy(from: pointPrefixURL, to: stagingURL)

        var restoredEnvironment = environment
        restoredEnvironment.profileID = manifest.snapshot.profileID
        restoredEnvironment.pinnedEngineBuildID = manifest.snapshot.engineBuildID
        restoredEnvironment.provisionedEngineBuildID = manifest.snapshot.engineBuildID
        restoredEnvironment.graphicsBackend = manifest.snapshot.graphicsBackend
        restoredEnvironment.windowsVersion = manifest.snapshot.windowsVersion
        restoredEnvironment.enhancedSync = manifest.snapshot.enhancedSync
        restoredEnvironment.updatedAt = .now

        var sourceMoved = false
        var restoredPrefixInstalled = false
        do {
            try fileManager.moveItem(at: environment.prefixURL, to: rollbackURL)
            sourceMoved = true
            try fileManager.moveItem(at: stagingURL, to: environment.prefixURL)
            restoredPrefixInstalled = true
            try await store.commitRestorePoint(
                environment: restoredEnvironment,
                applications: manifest.snapshot.applications,
                launchEntries: manifest.snapshot.launchEntries,
                expectedEnvironment: environment,
                expectedStoreIdentifier: document.storeIdentifier
            )
            try fileManager.removeItem(at: rollbackURL)
            return manifest
        } catch {
            if restoredPrefixInstalled,
               fileManager.fileExists(atPath: environment.prefixURL.path) {
                try? fileManager.removeItem(at: environment.prefixURL)
            }
            if sourceMoved, fileManager.fileExists(atPath: rollbackURL.path) {
                do {
                    try fileManager.moveItem(at: rollbackURL, to: environment.prefixURL)
                } catch let rollbackError {
                    throw StillCoreError.verificationFailed(
                        "Restore failed and the original Environment could not be returned to its path: \(rollbackError.localizedDescription)"
                    )
                }
            }
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            throw error
        }
    }

    private func requireStopped(_ environmentID: UUID, sessions: [LaunchSession]) throws {
        if sessions.contains(where: {
            $0.environmentID == environmentID && $0.state.isActive
        }) {
            throw StillCoreError.environmentMustBeStopped(environmentID)
        }
    }

    private var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        value.dateEncodingStrategy = .iso8601
        return value
    }

    private var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}
