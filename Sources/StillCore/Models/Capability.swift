import Foundation

public enum RuntimeCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case win64
    case wow64
    case esync
    case msync
    case metal
    case rosetta
    case wineD3D
    case dxmt
    case dxmtBridge
    case dxvk
    case vkd3d
    case vulkanBridge
    case d3dMetal
}

public struct HostCapabilitySnapshot: Codable, Hashable, Sendable {
    public enum Architecture: String, Codable, Sendable {
        case arm64
        case x86_64
    }

    public let architecture: Architecture
    public let supportsMetal: Bool
    public let supportsRosetta: Bool
    public let acceptedLicenseIDs: Set<String>

    public init(
        architecture: Architecture,
        supportsMetal: Bool,
        supportsRosetta: Bool,
        acceptedLicenseIDs: Set<String> = []
    ) {
        self.architecture = architecture
        self.supportsMetal = supportsMetal
        self.supportsRosetta = supportsRosetta
        self.acceptedLicenseIDs = acceptedLicenseIDs
    }
}

public struct CapabilityAvailability: Codable, Hashable, Sendable {
    public let isAvailable: Bool
    public let reason: String?

    public static func available() -> Self {
        Self(isAvailable: true, reason: nil)
    }

    public static func unavailable(_ reason: String) -> Self {
        Self(isAvailable: false, reason: reason)
    }
}
