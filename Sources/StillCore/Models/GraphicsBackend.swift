import Foundation

public enum GraphicsBackend: String, CaseIterable, Codable, Hashable, Sendable {
    case wineD3D
    case dxmt
    case dxvk
    case vkd3d
    case d3dMetal

    public var displayName: String {
        switch self {
        case .wineD3D:
            "WineD3D"
        case .dxmt:
            "DXMT"
        case .dxvk:
            "DXVK"
        case .vkd3d:
            "VKD3D"
        case .d3dMetal:
            "D3DMetal"
        }
    }

    public var requiresExternalLicenseAcceptance: Bool {
        self == .d3dMetal
    }
}

