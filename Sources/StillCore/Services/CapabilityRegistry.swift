import Foundation

public struct CapabilityRegistry: Sendable {
    private let availability: [RuntimeCapability: CapabilityAvailability]

    public init(
        host: HostCapabilitySnapshot,
        engine: EngineBuild,
        components: [RuntimeComponent],
        bridgeAvailability: CapabilityAvailability? = nil
    ) {
        let licensedComponents = components.filter { component in
            component.requiredLicenseID.map(host.acceptedLicenseIDs.contains) ?? true
        }
        let componentCapabilities = licensedComponents.reduce(into: Set<RuntimeCapability>()) {
            $0.formUnion($1.capabilities)
        }
        let engineLicensed = engine.requiredLicenseID.map(
            host.acceptedLicenseIDs.contains
        ) ?? true

        var available: Set<RuntimeCapability> = [.wineD3D]
        if host.supportsMetal { available.insert(.metal) }
        if host.supportsRosetta || host.architecture == .x86_64 { available.insert(.rosetta) }
        if engineLicensed {
            if engine.capabilities.contains(.win64) { available.insert(.win64) }
            if engine.capabilities.contains(.wow64) { available.insert(.wow64) }
            if engine.capabilities.contains(.esync) { available.insert(.esync) }
            if engine.capabilities.contains(.msync) { available.insert(.msync) }
            if engine.capabilities.contains(.d3dMetal) { available.insert(.d3dMetal) }
        }
        available.formUnion(componentCapabilities)
        if let bridgeAvailability {
            if bridgeAvailability.isAvailable {
                available.insert(.dxmtBridge)
            } else {
                available.remove(.dxmtBridge)
            }
        }

        var result: [RuntimeCapability: CapabilityAvailability] = [:]
        for capability in RuntimeCapability.allCases {
            if available.contains(capability) {
                result[capability] = .available()
            } else {
                result[capability] = .unavailable(
                    capability == .dxmtBridge ? bridgeAvailability?.reason ?? Self.unavailableReason(
                        capability,
                        host: host,
                        engine: engine,
                        components: components
                    ) : Self.unavailableReason(
                        capability,
                        host: host,
                        engine: engine,
                        components: components
                    )
                )
            }
        }
        availability = result
    }

    public func status(of capability: RuntimeCapability) -> CapabilityAvailability {
        availability[capability] ?? .unavailable("The capability was not evaluated.")
    }

    public func supports(_ capability: RuntimeCapability) -> Bool {
        status(of: capability).isAvailable
    }

    public func require(_ capabilities: Set<RuntimeCapability>) throws {
        for capability in capabilities where !supports(capability) {
            throw StillCoreError.unavailableCapability(
                capability.rawValue,
                status(of: capability).reason ?? "No reason was reported."
            )
        }
    }

    public func supportedGraphicsBackends() -> [GraphicsBackend] {
        GraphicsBackend.allCases.filter { backend in
            requiredCapabilities(for: backend).allSatisfy(supports)
        }
    }

    public func supportedSyncModes() -> [EnhancedSyncMode] {
        EnhancedSyncMode.allCases.filter { mode in
            requiredCapabilities(for: mode).allSatisfy(supports)
        }
    }

    public func requiredCapabilities(for backend: GraphicsBackend) -> Set<RuntimeCapability> {
        switch backend {
        case .wineD3D: [.wineD3D]
        case .dxmt: [.metal, .dxmt, .dxmtBridge]
        case .dxvk: [.dxvk, .vulkanBridge]
        case .vkd3d: [.vkd3d, .vulkanBridge]
        case .d3dMetal: [.metal, .d3dMetal]
        }
    }

    public func requiredCapabilities(for mode: EnhancedSyncMode) -> Set<RuntimeCapability> {
        switch mode {
        case .automatic, .none: []
        case .esync: [.esync]
        case .msync: [.msync]
        }
    }

    private static func unavailableReason(
        _ capability: RuntimeCapability,
        host: HostCapabilitySnapshot,
        engine: EngineBuild,
        components: [RuntimeComponent]
    ) -> String {
        if capability == .metal && !host.supportsMetal {
            return "This Mac does not provide the required Metal support."
        }
        if capability == .rosetta && host.architecture == .arm64 && !host.supportsRosetta {
            return "Rosetta is not available."
        }
        if let licenseID = engine.requiredLicenseID,
           !host.acceptedLicenseIDs.contains(licenseID) {
            return "The selected engine license has not been accepted."
        }
        if components.contains(where: {
            $0.capabilities.contains(capability)
                && $0.requiredLicenseID.map { !host.acceptedLicenseIDs.contains($0) } == true
        }) {
            return "A required component license has not been accepted."
        }
        return "The pinned engine or installed components do not provide it."
    }
}
