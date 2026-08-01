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
            metalTraceEnabled: environment.metalTraceEnabled
        )
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

    public func delete(
        preview: EnvironmentDeletionPreview,
        method: EnvironmentDeletionMethod,
        activeSessions: [LaunchSession],
        finalPermanentConfirmation: Bool
    ) throws -> URL? {
        try requireStopped(preview.environmentID, sessions: activeSessions)
        guard fileManager.fileExists(atPath: preview.prefixURL.path) else { return nil }
        switch method {
        case .moveToTrash:
            var resultingURL: NSURL?
            try fileManager.trashItem(
                at: preview.prefixURL,
                resultingItemURL: &resultingURL
            )
            return resultingURL as URL?
        case .permanentlyDelete:
            guard finalPermanentConfirmation else {
                throw StillCoreError.permanentDeletionConfirmationRequired
            }
            try fileManager.removeItem(at: preview.prefixURL)
            return nil
        }
    }

    private func requireStopped(_ environmentID: UUID, sessions: [LaunchSession]) throws {
        if sessions.contains(where: {
            $0.environmentID == environmentID && $0.state.isActive
        }) {
            throw StillCoreError.environmentMustBeStopped(environmentID)
        }
    }
}
