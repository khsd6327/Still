import Foundation

public struct EnvironmentRecoveryService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func duplicate(
        _ environment: WindowsEnvironment,
        name: String,
        managedRootURL: URL,
        activeSessions: [LaunchSession]
    ) throws -> WindowsEnvironment {
        try requireStopped(environment.id, sessions: activeSessions)
        let id = UUID()
        let destination = managedRootURL.appending(
            path: id.uuidString,
            directoryHint: .isDirectory
        )
        _ = try FileTreeServices.verifiedCopy(
            from: environment.prefixURL,
            to: destination
        )
        return WindowsEnvironment(
            id: id,
            name: name,
            prefixURL: destination,
            pinnedEngineBuildID: environment.pinnedEngineBuildID,
            provisionedEngineBuildID: environment.provisionedEngineBuildID,
            profileID: environment.profileID,
            graphicsBackend: environment.graphicsBackend,
            windowsVersion: environment.windowsVersion,
            enhancedSync: environment.enhancedSync,
            metalHUDEnabled: environment.metalHUDEnabled,
            metalTraceEnabled: environment.metalTraceEnabled,
            ownership: .managed,
            managementNonce: UUID()
        )
    }

    public func adoptManagedCopy(
        _ environment: WindowsEnvironment,
        managedRootURL: URL,
        engineBuildID: String,
        activeSessions: [LaunchSession]
    ) throws -> WindowsEnvironment {
        try requireStopped(environment.id, sessions: activeSessions)
        guard environment.ownership != .managed else {
            throw StillCoreError.invalidStore(
                "The Environment is already managed by Still."
            )
        }
        let destination = managedRootURL.appending(
            path: environment.id.uuidString,
            directoryHint: .isDirectory
        )
        guard environment.prefixURL.standardizedFileURL.path
            != destination.standardizedFileURL.path else {
            throw StillCoreError.invalidStore(
                "An unmanaged Environment cannot already use Still's managed path."
            )
        }
        _ = try FileTreeServices.verifiedCopy(
            from: environment.prefixURL,
            to: destination
        )
        var replacement = environment
        replacement.prefixURL = destination
        replacement.pinnedEngineBuildID = engineBuildID
        replacement.provisionedEngineBuildID = engineBuildID
        replacement.ownership = .managed
        replacement.managementNonce = UUID()
        replacement.updatedAt = .now
        return replacement
    }

    public func deletionPreview(
        environment: WindowsEnvironment,
        applications: [LibraryApplication]
    ) throws -> EnvironmentDeletionPreview {
        EnvironmentDeletionPreview(
            environmentID: environment.id,
            environmentName: environment.name,
            prefixURL: environment.prefixURL,
            affectedApplications: applications.filter {
                $0.environmentID == environment.id
            },
            estimatedByteCount: fileManager.fileExists(atPath: environment.prefixURL.path)
                ? try FileTreeServices.directorySize(environment.prefixURL)
                : 0
        )
    }

    private func requireStopped(_ environmentID: UUID, sessions: [LaunchSession]) throws {
        if sessions.contains(where: {
            $0.environmentID == environmentID && $0.state.isActive
        }) {
            throw StillCoreError.environmentMustBeStopped(environmentID)
        }
    }
}
