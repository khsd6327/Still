import Foundation

public struct DXMTBridgeValidator: Sendable {
    public init() {}

    public func validate(engine: EngineDescriptor) -> CapabilityAvailability {
        let root = runtimeRoot(for: engine.wineBinaryURL)
        let manifestURL = root.appending(path: "share/still/dxmt-bridge.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return .unavailable("The selected engine has no direct DXMT bridge manifest.")
        }
        do {
            let manifest = try JSONDecoder().decode(
                DXMTBridgeManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            guard manifest.contractID == DXMTBridgeManifest.contract else {
                return .unavailable("The DXMT bridge contract identifier is incompatible.")
            }
            guard manifest.abiVersion == DXMTBridgeManifest.supportedABIVersion else {
                return .unavailable(
                    "The DXMT bridge ABI is \(manifest.abiVersion); Still requires \(DXMTBridgeManifest.supportedABIVersion)."
                )
            }
            guard (engine.wineVersion ?? engine.version) == manifest.wineVersion else {
                return .unavailable("The DXMT bridge was built for a different Wine version.")
            }
            if let recordedRevision = engine.dxmtRevision,
               recordedRevision != manifest.dxmtRevision {
                return .unavailable("The DXMT bridge revision does not match the engine manifest.")
            }
            guard !manifest.dxmtRevision.isEmpty, !manifest.artifacts.isEmpty else {
                return .unavailable("The DXMT bridge manifest is incomplete.")
            }
            for artifact in manifest.artifacts {
                guard isSafeRelativePath(artifact.relativePath) else {
                    return .unavailable("The DXMT bridge manifest contains an unsafe artifact path.")
                }
                let url = root.appending(path: artifact.relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return .unavailable("A direct DXMT bridge artifact is missing.")
                }
                try SHA256Verifier.verify(fileURL: url, expectedDigest: artifact.sha256)
            }
            return .available()
        } catch {
            return .unavailable("The direct DXMT bridge failed integrity validation: \(error.localizedDescription)")
        }
    }

    public func runtimeRoot(for wineBinaryURL: URL) -> URL {
        let macOSDirectory = wineBinaryURL.deletingLastPathComponent()
        let contentsDirectory = macOSDirectory.deletingLastPathComponent()
        if macOSDirectory.lastPathComponent == "MacOS",
           contentsDirectory.lastPathComponent == "Contents" {
            let bundledRuntime = contentsDirectory.appending(
                path: "Resources/wine",
                directoryHint: .isDirectory
            )
            if FileManager.default.fileExists(atPath: bundledRuntime.path) {
                return bundledRuntime
            }
        }
        return wineBinaryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.split(separator: "/").contains("..")
    }
}
