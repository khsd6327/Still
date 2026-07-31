import Foundation

public enum EnhancedSyncMode: String, CaseIterable, Codable, Hashable, Sendable {
    case automatic
    case none
    case esync
    case msync

    public var displayName: String {
        switch self {
        case .automatic:
            "Automatic"
        case .none:
            "Disabled"
        case .esync:
            "ESync"
        case .msync:
            "MSync"
        }
    }
}

public struct Bottle: Codable, Hashable, Identifiable, Sendable {
    public enum WindowsVersion: String, CaseIterable, Codable, Sendable {
        case windows10
        case windows11
    }

    public let id: UUID
    public var name: String
    public let prefixURL: URL
    public var engineID: String?
    public let provisionedEngineID: String?
    public var recipeID: String?
    public var graphicsBackend: GraphicsBackend
    public var windowsVersion: WindowsVersion
    public var enhancedSync: EnhancedSyncMode
    public var metalHUDEnabled: Bool
    public var metalTraceEnabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        prefixURL: URL,
        engineID: String? = nil,
        provisionedEngineID: String? = nil,
        recipeID: String? = nil,
        graphicsBackend: GraphicsBackend = .wineD3D,
        windowsVersion: WindowsVersion = .windows10,
        enhancedSync: EnhancedSyncMode = .automatic,
        metalHUDEnabled: Bool = false,
        metalTraceEnabled: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.prefixURL = prefixURL
        self.engineID = engineID
        self.provisionedEngineID = provisionedEngineID ?? engineID
        self.recipeID = recipeID
        self.graphicsBackend = graphicsBackend
        self.windowsVersion = windowsVersion
        self.enhancedSync = enhancedSync
        self.metalHUDEnabled = metalHUDEnabled
        self.metalTraceEnabled = metalTraceEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case prefixURL
        case engineID
        case provisionedEngineID
        case recipeID
        case graphicsBackend
        case windowsVersion
        case enhancedSync
        case metalHUDEnabled
        case metalTraceEnabled
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        prefixURL = try values.decode(URL.self, forKey: .prefixURL)
        engineID = try values.decodeIfPresent(String.self, forKey: .engineID)
        provisionedEngineID = try values.decodeIfPresent(
            String.self,
            forKey: .provisionedEngineID
        ) ?? engineID
        recipeID = try values.decodeIfPresent(String.self, forKey: .recipeID)
        graphicsBackend = try values.decodeIfPresent(
            GraphicsBackend.self,
            forKey: .graphicsBackend
        ) ?? .wineD3D
        windowsVersion = try values.decodeIfPresent(
            WindowsVersion.self,
            forKey: .windowsVersion
        ) ?? .windows10
        enhancedSync = try values.decodeIfPresent(
            EnhancedSyncMode.self,
            forKey: .enhancedSync
        ) ?? .automatic
        metalHUDEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .metalHUDEnabled
        ) ?? false
        metalTraceEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .metalTraceEnabled
        ) ?? false
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}
