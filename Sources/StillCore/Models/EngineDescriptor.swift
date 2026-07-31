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
}

public struct EngineDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let version: String
    public let wineBinaryURL: URL
    public let capabilities: EngineCapabilities

    public init(
        id: String,
        displayName: String,
        version: String,
        wineBinaryURL: URL,
        capabilities: EngineCapabilities
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.wineBinaryURL = wineBinaryURL
        self.capabilities = capabilities
    }
}
