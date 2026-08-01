import Foundation

public struct EngineBuild: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var family: EngineFamily
    public var displayName: String
    public var version: String
    public var installURL: URL
    public var capabilities: EngineCapabilities
    public var manifestID: String?
    public var requiredLicenseID: String?

    public init(
        id: String,
        family: EngineFamily,
        displayName: String,
        version: String,
        installURL: URL,
        capabilities: EngineCapabilities,
        manifestID: String? = nil,
        requiredLicenseID: String? = nil
    ) {
        self.id = id
        self.family = family
        self.displayName = displayName
        self.version = version
        self.installURL = installURL
        self.capabilities = capabilities
        self.manifestID = manifestID
        self.requiredLicenseID = requiredLicenseID
    }

    private enum CodingKeys: String, CodingKey {
        case id, family, displayName, version, installURL, capabilities
        case manifestID, requiredLicenseID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        family = try values.decode(EngineFamily.self, forKey: .family)
        displayName = try values.decode(String.self, forKey: .displayName)
        version = try values.decode(String.self, forKey: .version)
        installURL = try values.decode(URL.self, forKey: .installURL)
        capabilities = try values.decode(EngineCapabilities.self, forKey: .capabilities)
        manifestID = try values.decodeIfPresent(String.self, forKey: .manifestID)
        requiredLicenseID = try values.decodeIfPresent(String.self, forKey: .requiredLicenseID)
    }
}

public struct RuntimeComponent: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var displayName: String
    public var version: String
    public var installURL: URL
    public var sha256: String?
    public var capabilities: Set<RuntimeCapability>
    public var requiredLicenseID: String?

    public init(
        id: String,
        displayName: String,
        version: String,
        installURL: URL,
        sha256: String? = nil,
        capabilities: Set<RuntimeCapability> = [],
        requiredLicenseID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.installURL = installURL
        self.sha256 = sha256
        self.capabilities = capabilities
        self.requiredLicenseID = requiredLicenseID
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, version, installURL, sha256, capabilities
        case requiredLicenseID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        version = try values.decode(String.self, forKey: .version)
        installURL = try values.decode(URL.self, forKey: .installURL)
        sha256 = try values.decodeIfPresent(String.self, forKey: .sha256)
        capabilities = try values.decodeIfPresent(
            Set<RuntimeCapability>.self,
            forKey: .capabilities
        ) ?? []
        requiredLicenseID = try values.decodeIfPresent(String.self, forKey: .requiredLicenseID)
    }
}
