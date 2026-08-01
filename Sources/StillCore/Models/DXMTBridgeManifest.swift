import Foundation

public struct DXMTBridgeArtifact: Codable, Hashable, Sendable {
    public let relativePath: String
    public let sha256: String

    public init(relativePath: String, sha256: String) {
        self.relativePath = relativePath
        self.sha256 = sha256.lowercased()
    }
}

public struct DXMTBridgeManifest: Codable, Hashable, Sendable {
    public static let contract = "app.stillproject.dxmt-bridge"
    public static let supportedABIVersion = 1

    public let contractID: String
    public let abiVersion: Int
    public let wineVersion: String
    public let dxmtRevision: String
    public let artifacts: [DXMTBridgeArtifact]

    public init(
        contractID: String = Self.contract,
        abiVersion: Int = Self.supportedABIVersion,
        wineVersion: String,
        dxmtRevision: String,
        artifacts: [DXMTBridgeArtifact]
    ) {
        self.contractID = contractID
        self.abiVersion = abiVersion
        self.wineVersion = wineVersion
        self.dxmtRevision = dxmtRevision
        self.artifacts = artifacts
    }
}
