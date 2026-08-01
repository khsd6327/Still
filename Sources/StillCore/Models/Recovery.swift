import Foundation

public struct ConfigurationSnapshot: Codable, Hashable, Sendable {
    public let environmentID: WindowsEnvironment.ID
    public let profileID: String?
    public let engineBuildID: String?
    public let graphicsBackend: GraphicsBackend
    public let windowsVersion: Bottle.WindowsVersion
    public let enhancedSync: EnhancedSyncMode
    public let applications: [LibraryApplication]
    public let launchEntries: [LaunchEntry]
    public let createdAt: Date

    public init(
        environment: WindowsEnvironment,
        applications: [LibraryApplication],
        launchEntries: [LaunchEntry],
        createdAt: Date = .now
    ) {
        environmentID = environment.id
        profileID = environment.profileID
        engineBuildID = environment.pinnedEngineBuildID
        graphicsBackend = environment.graphicsBackend
        windowsVersion = environment.windowsVersion
        enhancedSync = environment.enhancedSync
        self.applications = applications.filter { $0.environmentID == environment.id }
        let applicationIDs = Set(self.applications.map(\.id))
        self.launchEntries = launchEntries.filter { applicationIDs.contains($0.applicationID) }
        self.createdAt = createdAt
    }
}

public struct RestorePointManifest: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let environmentID: WindowsEnvironment.ID
    public let environmentName: String
    public let createdAt: Date
    public let snapshot: ConfigurationSnapshot
    public let requiredEngineBuildID: String?
    public let affectedApplicationIDs: [LibraryApplication.ID]
    public let fileCount: Int
    public let byteCount: Int64
    public let usedCloneCopy: Bool
    public var isProtected: Bool
}

public struct BackupManifest: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let createdAt: Date
    public let environment: WindowsEnvironment
    public let snapshot: ConfigurationSnapshot
    public let requiredEngineBuildID: String?
    public let requiredComponents: [String: String]
    public let excludedCategories: [String]
    public let fileCount: Int
    public let byteCount: Int64
}

public struct BackupPreview: Hashable, Sendable {
    public let manifest: BackupManifest
    public let destinationURL: URL
    public let isEncrypted: Bool
}

public enum RepairSeverity: String, Codable, Sendable {
    case warning
    case blocking
}

public enum TypedRepairAction: Codable, Hashable, Sendable {
    case createPrefixDirectory
    case selectInstalledEngine
    case removeMissingLaunchEntry(UUID)
    case installComponent(id: String, exactVersion: String)
}

public struct RepairIssue: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let severity: RepairSeverity
    public let summary: String
    public let proposedAction: TypedRepairAction?
}

public struct RepairReport: Codable, Hashable, Identifiable, Sendable {
    public let environmentID: WindowsEnvironment.ID
    public let inspectedAt: Date
    public let issues: [RepairIssue]
    public var id: WindowsEnvironment.ID { environmentID }
    public var isHealthy: Bool { issues.isEmpty }
}

public enum EnvironmentDeletionMethod: String, CaseIterable, Codable, Sendable {
    case moveToTrash
    case permanentlyDelete
}

public struct EnvironmentDeletionPreview: Hashable, Identifiable, Sendable {
    public let environmentID: WindowsEnvironment.ID
    public let environmentName: String
    public let prefixURL: URL
    public let affectedApplications: [LibraryApplication]
    public let estimatedByteCount: Int64
    public var id: WindowsEnvironment.ID { environmentID }
}

public enum MutationPhase: String, Codable, Sendable {
    case cancellablePreparation
    case nonCancellableCommit
    case rollback
    case complete
}

public enum EnvironmentDeletionJournalState: String, Codable, Sendable {
    case prepared
    case quarantined
    case storeCommitted
    case cleanupPending
    case rolledBack
}

public struct EnvironmentDeletionJournal: Codable, Equatable, Identifiable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let id: UUID
    public let storeIdentifier: UUID
    public let environmentID: WindowsEnvironment.ID
    public let managementNonce: UUID
    public let originalPrefixURL: URL
    public let quarantineURL: URL
    public let method: EnvironmentDeletionMethod
    public var state: EnvironmentDeletionJournalState
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        version: Int = Self.currentVersion,
        id: UUID = UUID(),
        storeIdentifier: UUID,
        environmentID: WindowsEnvironment.ID,
        managementNonce: UUID,
        originalPrefixURL: URL,
        quarantineURL: URL,
        method: EnvironmentDeletionMethod,
        state: EnvironmentDeletionJournalState = .prepared,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.version = version
        self.id = id
        self.storeIdentifier = storeIdentifier
        self.environmentID = environmentID
        self.managementNonce = managementNonce
        self.originalPrefixURL = originalPrefixURL
        self.quarantineURL = quarantineURL
        self.method = method
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
