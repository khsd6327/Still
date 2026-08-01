import Foundation

public struct InstalledEngineArtifact: Codable, Hashable, Sendable {
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int64
    public let isExecutable: Bool

    public init(
        relativePath: String,
        sha256: String,
        byteCount: Int64,
        isExecutable: Bool
    ) {
        self.relativePath = relativePath
        self.sha256 = sha256.lowercased()
        self.byteCount = byteCount
        self.isExecutable = isExecutable
    }
}

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
    public let artifacts: [InstalledEngineArtifact]

    public init(
        contractID: String = Self.contract,
        schemaVersion: Int = Self.supportedSchemaVersion,
        id: String,
        family: EngineFamily,
        displayName: String,
        version: String,
        archiveRoot: String,
        wineBinaryRelativePath: String,
        capabilities: EngineCapabilities,
        artifacts: [InstalledEngineArtifact] = []
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
        self.artifacts = artifacts
    }

    private enum CodingKeys: String, CodingKey {
        case contractID, schemaVersion, id, family, displayName, version
        case archiveRoot, wineBinaryRelativePath, capabilities, artifacts
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        contractID = try values.decode(String.self, forKey: .contractID)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(String.self, forKey: .id)
        family = try values.decode(EngineFamily.self, forKey: .family)
        displayName = try values.decode(String.self, forKey: .displayName)
        version = try values.decode(String.self, forKey: .version)
        archiveRoot = try values.decode(String.self, forKey: .archiveRoot)
        wineBinaryRelativePath = try values.decode(
            String.self,
            forKey: .wineBinaryRelativePath
        )
        capabilities = try values.decode(EngineCapabilities.self, forKey: .capabilities)
        artifacts = try values.decodeIfPresent(
            [InstalledEngineArtifact].self,
            forKey: .artifacts
        ) ?? []
    }
}
