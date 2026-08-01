import Foundation

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
            createdAt: bottle.createdAt,
            updatedAt: bottle.updatedAt
        )
    }
}
