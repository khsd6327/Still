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
