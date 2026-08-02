import Foundation

public struct EngineCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let win64 = Self(rawValue: 1 << 0)
    public static let wow64 = Self(rawValue: 1 << 1)
    public static let msync = Self(rawValue: 1 << 2)
    public static let esync = Self(rawValue: 1 << 3)
    public static let d3dMetal = Self(rawValue: 1 << 4)
    public static let dxmt = Self(rawValue: 1 << 5)
}

public struct EngineDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let version: String
    public let wineVersion: String?
    public let dxmtRevision: String?
    public let family: EngineFamily?
    public let wineBinaryURL: URL
    public let capabilities: EngineCapabilities
    public let sourceArchiveSHA256: String?
    public let artifactManifestSHA256: String?

    public init(
        id: String,
        displayName: String,
        version: String,
        wineVersion: String? = nil,
        dxmtRevision: String? = nil,
        family: EngineFamily? = nil,
        wineBinaryURL: URL,
        capabilities: EngineCapabilities,
        sourceArchiveSHA256: String? = nil,
        artifactManifestSHA256: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.wineVersion = wineVersion
        self.dxmtRevision = dxmtRevision
        self.family = family
        self.wineBinaryURL = wineBinaryURL
        self.capabilities = capabilities
        self.sourceArchiveSHA256 = sourceArchiveSHA256
        self.artifactManifestSHA256 = artifactManifestSHA256
    }
}
