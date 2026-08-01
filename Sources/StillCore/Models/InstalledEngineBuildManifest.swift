import Foundation

public struct InstalledEngineBuildManifest: Codable, Hashable, Sendable {
    public static let contract = "app.stillproject.engine-build"
    public static let supportedSchemaVersion = 1
    public static let fileName = "still-engine.json"

    public let contractID: String
    public let schemaVersion: Int
    public let id: String
    public let family: EngineFamily
    public let displayName: String
    public let version: String
    public let archiveRoot: String
    public let wineBinaryRelativePath: String
    public let capabilities: EngineCapabilities

    public init(
        contractID: String = Self.contract,
        schemaVersion: Int = Self.supportedSchemaVersion,
        id: String,
        family: EngineFamily,
        displayName: String,
        version: String,
        archiveRoot: String,
        wineBinaryRelativePath: String,
        capabilities: EngineCapabilities
    ) {
        self.contractID = contractID
        self.schemaVersion = schemaVersion
        self.id = id
        self.family = family
        self.displayName = displayName
        self.version = version
        self.archiveRoot = archiveRoot
        self.wineBinaryRelativePath = wineBinaryRelativePath
        self.capabilities = capabilities
    }
}
