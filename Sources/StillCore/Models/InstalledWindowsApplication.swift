import Foundation

public enum WindowsApplicationSource: String, Codable, Hashable, Sendable {
    case steam
    case standalone
    case office
    case pinned

    public var displayName: String {
        switch self {
        case .steam:
            "Steam"
        case .standalone:
            "Windows"
        case .office:
            "Microsoft Office"
        case .pinned:
            "Pinned"
        }
    }
}

public enum WindowsApplicationInstallState: String, Codable, Hashable, Sendable {
    case installed
    case downloading
    case needsUpdate
    case unknown
}

public struct InstalledWindowsApplication: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let source: WindowsApplicationSource
    public let sourceIdentifier: String?
    public let installState: WindowsApplicationInstallState
    public let installDirectoryURL: URL
    public let launcherURL: URL
    public let launchArguments: [String]
    public let sizeOnDisk: Int64?

    public init(
        id: String,
        name: String,
        source: WindowsApplicationSource,
        sourceIdentifier: String? = nil,
        installState: WindowsApplicationInstallState,
        installDirectoryURL: URL,
        launcherURL: URL,
        launchArguments: [String] = [],
        sizeOnDisk: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.sourceIdentifier = sourceIdentifier
        self.installState = installState
        self.installDirectoryURL = installDirectoryURL
        self.launcherURL = launcherURL
        self.launchArguments = launchArguments
        self.sizeOnDisk = sizeOnDisk
    }
}
