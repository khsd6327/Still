import Foundation

public enum LibraryApplicationCategory: String, Codable, Hashable, Sendable {
    case game
    case application
    case productivity
    case launcher
    case unknown
}

public struct LibraryApplication: Codable, Hashable, Identifiable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public var environmentID: WindowsEnvironment.ID
    public var name: String
    public var category: LibraryApplicationCategory
    public var providerID: String?
    public var providerItemID: String?
    public var launchEntryIDs: [LaunchEntry.ID]
    public var selectedProfileID: String?
    public var isFavorite: Bool
    public var isHidden: Bool
    public var lastLaunchedAt: Date?
    public var providerManagedState: WindowsApplicationInstallState?
    public var lastDiscoveryGeneration: UUID?

    public init(
        id: ID = UUID(),
        environmentID: WindowsEnvironment.ID,
        name: String,
        category: LibraryApplicationCategory = .unknown,
        providerID: String? = nil,
        providerItemID: String? = nil,
        launchEntryIDs: [LaunchEntry.ID] = [],
        selectedProfileID: String? = nil,
        isFavorite: Bool = false,
        isHidden: Bool = false,
        lastLaunchedAt: Date? = nil,
        providerManagedState: WindowsApplicationInstallState? = nil,
        lastDiscoveryGeneration: UUID? = nil
    ) {
        self.id = id
        self.environmentID = environmentID
        self.name = name
        self.category = category
        self.providerID = providerID
        self.providerItemID = providerItemID
        self.launchEntryIDs = launchEntryIDs
        self.selectedProfileID = selectedProfileID
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.lastLaunchedAt = lastLaunchedAt
        self.providerManagedState = providerManagedState
        self.lastDiscoveryGeneration = lastDiscoveryGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case id, environmentID, name, category, providerID, providerItemID
        case launchEntryIDs, selectedProfileID, isFavorite, isHidden
        case lastLaunchedAt, providerManagedState, lastDiscoveryGeneration
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(ID.self, forKey: .id)
        environmentID = try values.decode(WindowsEnvironment.ID.self, forKey: .environmentID)
        name = try values.decode(String.self, forKey: .name)
        category = try values.decode(LibraryApplicationCategory.self, forKey: .category)
        providerID = try values.decodeIfPresent(String.self, forKey: .providerID)
        providerItemID = try values.decodeIfPresent(String.self, forKey: .providerItemID)
        launchEntryIDs = try values.decodeIfPresent([LaunchEntry.ID].self, forKey: .launchEntryIDs) ?? []
        selectedProfileID = try values.decodeIfPresent(String.self, forKey: .selectedProfileID)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isHidden = try values.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        lastLaunchedAt = try values.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)
        providerManagedState = try values.decodeIfPresent(
            WindowsApplicationInstallState.self,
            forKey: .providerManagedState
        )
        lastDiscoveryGeneration = try values.decodeIfPresent(
            UUID.self,
            forKey: .lastDiscoveryGeneration
        )
    }
}

public struct LaunchEntry: Codable, Hashable, Identifiable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public let applicationID: LibraryApplication.ID
    public var executableURL: URL
    public var arguments: [String]
    public var workingDirectoryURL: URL?

    public init(
        id: ID = UUID(),
        applicationID: LibraryApplication.ID,
        executableURL: URL,
        arguments: [String] = [],
        workingDirectoryURL: URL? = nil
    ) {
        self.id = id
        self.applicationID = applicationID
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
    }
}
