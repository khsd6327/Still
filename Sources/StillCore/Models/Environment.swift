import Foundation

public enum EnvironmentOwnership: String, Codable, CaseIterable, Hashable, Sendable {
    case managed
    case importedInPlace
    case externalReadOnly
    case unknown

    public var displayName: String {
        switch self {
        case .managed: "Managed by Still"
        case .importedInPlace: "External"
        case .externalReadOnly: "External, Read Only"
        case .unknown: "Ownership Unknown"
        }
    }
}

public struct WindowsEnvironment: Codable, Hashable, Identifiable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public var name: String
    public var prefixURL: URL
    public var pinnedEngineBuildID: String?
    public var provisionedEngineBuildID: String?
    public var profileID: String?
    public var graphicsBackend: GraphicsBackend
    public var windowsVersion: Bottle.WindowsVersion
    public var enhancedSync: EnhancedSyncMode
    public var metalHUDEnabled: Bool
    public var metalTraceEnabled: Bool
    public var ownership: EnvironmentOwnership
    public var managementNonce: UUID?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: ID = UUID(),
        name: String,
        prefixURL: URL,
        pinnedEngineBuildID: String? = nil,
        provisionedEngineBuildID: String? = nil,
        profileID: String? = nil,
        graphicsBackend: GraphicsBackend = .wineD3D,
        windowsVersion: Bottle.WindowsVersion = .windows10,
        enhancedSync: EnhancedSyncMode = .automatic,
        metalHUDEnabled: Bool = false,
        metalTraceEnabled: Bool = false,
        ownership: EnvironmentOwnership = .unknown,
        managementNonce: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.prefixURL = prefixURL
        self.pinnedEngineBuildID = pinnedEngineBuildID
        self.provisionedEngineBuildID = provisionedEngineBuildID
        self.profileID = profileID
        self.graphicsBackend = graphicsBackend
        self.windowsVersion = windowsVersion
        self.enhancedSync = enhancedSync
        self.metalHUDEnabled = metalHUDEnabled
        self.metalTraceEnabled = metalTraceEnabled
        self.ownership = ownership
        self.managementNonce = managementNonce
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(migrating bottle: Bottle) {
        self.init(
            id: bottle.id,
            name: bottle.name,
            prefixURL: bottle.prefixURL,
            pinnedEngineBuildID: bottle.engineID,
            provisionedEngineBuildID: bottle.provisionedEngineID,
            profileID: bottle.recipeID,
            graphicsBackend: bottle.graphicsBackend,
            windowsVersion: bottle.windowsVersion,
            enhancedSync: bottle.enhancedSync,
            metalHUDEnabled: bottle.metalHUDEnabled,
            metalTraceEnabled: bottle.metalTraceEnabled,
            ownership: .unknown,
            createdAt: bottle.createdAt,
            updatedAt: bottle.updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, prefixURL, pinnedEngineBuildID, provisionedEngineBuildID
        case profileID, graphicsBackend, windowsVersion, enhancedSync
        case metalHUDEnabled, metalTraceEnabled, ownership, managementNonce
        case createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(ID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        prefixURL = try values.decode(URL.self, forKey: .prefixURL)
        pinnedEngineBuildID = try values.decodeIfPresent(String.self, forKey: .pinnedEngineBuildID)
        provisionedEngineBuildID = try values.decodeIfPresent(
            String.self,
            forKey: .provisionedEngineBuildID
        )
        profileID = try values.decodeIfPresent(String.self, forKey: .profileID)
        graphicsBackend = try values.decode(GraphicsBackend.self, forKey: .graphicsBackend)
        windowsVersion = try values.decode(Bottle.WindowsVersion.self, forKey: .windowsVersion)
        enhancedSync = try values.decode(EnhancedSyncMode.self, forKey: .enhancedSync)
        metalHUDEnabled = try values.decodeIfPresent(Bool.self, forKey: .metalHUDEnabled) ?? false
        metalTraceEnabled = try values.decodeIfPresent(Bool.self, forKey: .metalTraceEnabled) ?? false
        ownership = try values.decodeIfPresent(
            EnvironmentOwnership.self,
            forKey: .ownership
        ) ?? .unknown
        managementNonce = try values.decodeIfPresent(UUID.self, forKey: .managementNonce)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}
