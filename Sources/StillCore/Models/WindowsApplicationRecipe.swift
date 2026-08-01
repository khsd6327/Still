import Foundation

public struct LocalInstallerRequirements: Codable, Hashable, Sendable {
    public let acceptedFileNames: Set<String>
    public let acceptedExtensions: Set<String>
    public let arguments: [String]

    public init(
        acceptedFileNames: Set<String> = [],
        acceptedExtensions: Set<String> = ["exe", "msi"],
        arguments: [String] = []
    ) {
        self.acceptedFileNames = acceptedFileNames
        self.acceptedExtensions = acceptedExtensions
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
    public let installer: LocalInstallerRequirements?
    public let supportStatus: String

    public init(
        id: String,
        displayName: String,
        defaultBottleName: String,
        preferredEngineFamily: EngineFamily,
        windowsVersion: Bottle.WindowsVersion,
        graphicsBackend: GraphicsBackend,
        installer: LocalInstallerRequirements?,
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
