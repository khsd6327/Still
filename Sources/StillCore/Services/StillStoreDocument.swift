import Foundation

public struct StillStoreDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public var revision: UInt64
    public var environments: [WindowsEnvironment]
    public var applications: [LibraryApplication]
    public var launchEntries: [LaunchEntry]
    public var engineBuilds: [EngineBuild]
    public var components: [RuntimeComponent]
    public var operations: [StillOperation]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        revision: UInt64 = 0,
        environments: [WindowsEnvironment] = [],
        applications: [LibraryApplication] = [],
        launchEntries: [LaunchEntry] = [],
        engineBuilds: [EngineBuild] = [],
        components: [RuntimeComponent] = [],
        operations: [StillOperation] = []
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.environments = environments
        self.applications = applications
        self.launchEntries = launchEntries
        self.engineBuilds = engineBuilds
        self.components = components
        self.operations = operations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, environments, applications, launchEntries
        case engineBuilds, components, operations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        environments = try container.decode([WindowsEnvironment].self, forKey: .environments)
        applications = try container.decode([LibraryApplication].self, forKey: .applications)
        launchEntries = try container.decode([LaunchEntry].self, forKey: .launchEntries)
        engineBuilds = try container.decodeIfPresent([EngineBuild].self, forKey: .engineBuilds) ?? []
        components = try container.decodeIfPresent([RuntimeComponent].self, forKey: .components) ?? []
        operations = try container.decodeIfPresent([StillOperation].self, forKey: .operations) ?? []
    }
}
