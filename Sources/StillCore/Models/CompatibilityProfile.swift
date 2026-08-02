import Foundation

public enum CompatibilityValueSource: Codable, Hashable, Sendable {
    case safeFallback
    case environment
    case profile(String)
    case runtimePolicy(String)
    case applicationOverride
    case launchOverride
}

public struct SourcedValue<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let value: Value
    public let source: CompatibilityValueSource

    public init(_ value: Value, source: CompatibilityValueSource) {
        self.value = value
        self.source = source
    }
}

public struct CompatibilitySettings: Codable, Hashable, Sendable {
    public var windowsVersion: Bottle.WindowsVersion?
    public var graphicsBackend: GraphicsBackend?
    public var enhancedSync: EnhancedSyncMode?
    public var environmentVariables: [String: String]
    public var launchArguments: [String]

    public init(
        windowsVersion: Bottle.WindowsVersion? = nil,
        graphicsBackend: GraphicsBackend? = nil,
        enhancedSync: EnhancedSyncMode? = nil,
        environmentVariables: [String: String] = [:],
        launchArguments: [String] = []
    ) {
        self.windowsVersion = windowsVersion
        self.graphicsBackend = graphicsBackend
        self.enhancedSync = enhancedSync
        self.environmentVariables = environmentVariables
        self.launchArguments = launchArguments
    }
}

public struct ProfileMatchRule: Codable, Hashable, Sendable {
    public var providerID: String?
    public var providerItemID: String?
    public var executableNames: Set<String>

    public init(
        providerID: String? = nil,
        providerItemID: String? = nil,
        executableNames: Set<String> = []
    ) {
        self.providerID = providerID
        self.providerItemID = providerItemID
        self.executableNames = executableNames
    }
}

public struct ComponentDependency: Codable, Hashable, Sendable {
    public let componentID: String
    public let exactVersion: String

    public init(componentID: String, exactVersion: String) {
        self.componentID = componentID
        self.exactVersion = exactVersion
    }
}

public struct CompatibilityProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let matchRules: [ProfileMatchRule]
    public let requiredEngineFamily: EngineFamily?
    public let requiredEngineID: String?
    public let requiredDXMTRevision: String?
    public let requiredArtifactManifestSHA256: String?
    public let requiredCapabilities: Set<RuntimeCapability>
    public let dependencies: [ComponentDependency]
    public let recommendedSettings: CompatibilitySettings
    public let validationEvidence: [String]

    public init(
        id: String,
        displayName: String,
        matchRules: [ProfileMatchRule],
        requiredEngineFamily: EngineFamily? = nil,
        requiredEngineID: String? = nil,
        requiredDXMTRevision: String? = nil,
        requiredArtifactManifestSHA256: String? = nil,
        requiredCapabilities: Set<RuntimeCapability> = [],
        dependencies: [ComponentDependency] = [],
        recommendedSettings: CompatibilitySettings = CompatibilitySettings(),
        validationEvidence: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.matchRules = matchRules
        self.requiredEngineFamily = requiredEngineFamily
        self.requiredEngineID = requiredEngineID
        self.requiredDXMTRevision = requiredDXMTRevision
        self.requiredArtifactManifestSHA256 = requiredArtifactManifestSHA256?.lowercased()
        self.requiredCapabilities = requiredCapabilities
        self.dependencies = dependencies
        self.recommendedSettings = recommendedSettings
        self.validationEvidence = validationEvidence
    }
}

public struct RuntimeLaunchEvidence: Codable, Hashable, Sendable {
    public let profileID: String?
    public let engineID: String
    public let engineArtifactManifestSHA256: String?
    public let dxmtRevision: String?
    public let windowsVersion: Bottle.WindowsVersion
    public let graphicsBackend: GraphicsBackend
    public let enhancedSync: EnhancedSyncMode
    public let runtimePolicyID: String?

    public init(
        profileID: String?,
        engineID: String,
        engineArtifactManifestSHA256: String?,
        dxmtRevision: String?,
        windowsVersion: Bottle.WindowsVersion,
        graphicsBackend: GraphicsBackend,
        enhancedSync: EnhancedSyncMode,
        runtimePolicyID: String?
    ) {
        self.profileID = profileID
        self.engineID = engineID
        self.engineArtifactManifestSHA256 = engineArtifactManifestSHA256?.lowercased()
        self.dxmtRevision = dxmtRevision
        self.windowsVersion = windowsVersion
        self.graphicsBackend = graphicsBackend
        self.enhancedSync = enhancedSync
        self.runtimePolicyID = runtimePolicyID
    }
}

public struct EffectiveCompatibility: Codable, Hashable, Sendable {
    public let windowsVersion: SourcedValue<Bottle.WindowsVersion>
    public let graphicsBackend: SourcedValue<GraphicsBackend>
    public let enhancedSync: SourcedValue<EnhancedSyncMode>
    public let environmentVariables: [String: SourcedValue<String>]
    public let launchArguments: [String]
    public let launchArgumentSource: CompatibilityValueSource
}
