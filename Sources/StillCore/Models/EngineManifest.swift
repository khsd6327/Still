import Foundation

public enum EngineFamily: String, Codable, Hashable, Sendable {
    case wineStable
    case wineDevel
    case wineStaging
    case gamePortingToolkit
}

public enum EngineDistributionPolicy: String, Codable, Hashable, Sendable {
    case automaticDownload
    case externalLicenseRequired
}

public enum EngineArchiveFormat: String, Codable, Hashable, Sendable {
    case tarXZ
}

public struct EngineManifest: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let family: EngineFamily
    public let displayName: String
    public let version: String
    public let sourceURL: URL
    public let downloadURL: URL
    public let sha256: String
    public let downloadSize: Int64
    public let archiveFormat: EngineArchiveFormat
    public let archiveRoot: String
    public let wineBinaryRelativePath: String
    public let capabilities: EngineCapabilities
    public let requirements: [String]
    public let distributionPolicy: EngineDistributionPolicy
    public let licenseURL: URL?

    public init(
        id: String,
        family: EngineFamily,
        displayName: String,
        version: String,
        sourceURL: URL,
        downloadURL: URL,
        sha256: String,
        downloadSize: Int64,
        archiveFormat: EngineArchiveFormat = .tarXZ,
        archiveRoot: String,
        wineBinaryRelativePath: String,
        capabilities: EngineCapabilities,
        requirements: [String] = [],
        distributionPolicy: EngineDistributionPolicy = .automaticDownload,
        licenseURL: URL? = nil
    ) {
        self.id = id
        self.family = family
        self.displayName = displayName
        self.version = version
        self.sourceURL = sourceURL
        self.downloadURL = downloadURL
        self.sha256 = sha256.lowercased()
        self.downloadSize = downloadSize
        self.archiveFormat = archiveFormat
        self.archiveRoot = archiveRoot
        self.wineBinaryRelativePath = wineBinaryRelativePath
        self.capabilities = capabilities
        self.requirements = requirements
        self.distributionPolicy = distributionPolicy
        self.licenseURL = licenseURL
    }
}
