import Foundation

public struct WindowsInstallerArtifact: Codable, Hashable, Sendable {
    public let downloadURL: URL
    public let allowedHosts: Set<String>
    public let fileName: String
    public let arguments: [String]

    public init(
        downloadURL: URL,
        allowedHosts: Set<String>,
        fileName: String,
        arguments: [String] = []
    ) {
        self.downloadURL = downloadURL
        self.allowedHosts = allowedHosts
        self.fileName = fileName
        self.arguments = arguments
    }
}

public struct WindowsApplicationRecipe: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let defaultBottleName: String
    public let preferredEngineFamily: EngineFamily
    public let windowsVersion: Bottle.WindowsVersion
    public let graphicsBackend: GraphicsBackend
    public let installer: WindowsInstallerArtifact?
    public let supportStatus: String

    public init(
        id: String,
        displayName: String,
        defaultBottleName: String,
        preferredEngineFamily: EngineFamily,
        windowsVersion: Bottle.WindowsVersion,
        graphicsBackend: GraphicsBackend,
        installer: WindowsInstallerArtifact?,
        supportStatus: String
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultBottleName = defaultBottleName
        self.preferredEngineFamily = preferredEngineFamily
        self.windowsVersion = windowsVersion
        self.graphicsBackend = graphicsBackend
        self.installer = installer
        self.supportStatus = supportStatus
    }
}
