import Foundation
import XCTest
@testable import StillCore

final class DXMTBridgeValidatorTests: XCTestCase {
    func testValidatesPinnedABIAndArtifactIntegrity() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "StillBridgeValidation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let wine = root.appending(path: "bin/wine")
        let artifact = root.appending(path: "lib/wine/x86_64-unix/winemetal.so")
        let manifestURL = root.appending(path: "share/still/dxmt-bridge.json")
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("direct bridge".utf8).write(to: artifact)
        let manifest = DXMTBridgeManifest(
            wineVersion: "11.14",
            dxmtRevision: "3525d41c71604ed07d796de5b58560e3cf6db944",
            artifacts: [DXMTBridgeArtifact(
                relativePath: "lib/wine/x86_64-unix/winemetal.so",
                sha256: try SHA256Verifier.digest(of: artifact)
            )]
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let engine = EngineDescriptor(
            id: "direct", displayName: "Direct", version: "11.14",
            wineBinaryURL: wine, capabilities: [.win64]
        )

        XCTAssertTrue(DXMTBridgeValidator().validate(engine: engine).isAvailable)

        try Data("modified".utf8).write(to: artifact)
        let invalid = DXMTBridgeValidator().validate(engine: engine)
        XCTAssertFalse(invalid.isAvailable)
        XCTAssertTrue(invalid.reason?.contains("integrity") == true)
    }

    func testCapabilityRegistryReportsBridgeReason() {
        let host = HostCapabilitySnapshot(
            architecture: .arm64, supportsMetal: true, supportsRosetta: true
        )
        let engine = EngineBuild(
            id: "wine", family: .wineStaging, displayName: "Wine",
            version: "11.14", installURL: URL(filePath: "/tmp/wine"),
            capabilities: [.win64]
        )
        let component = RuntimeComponent(
            id: "dxmt", displayName: "DXMT", version: "test",
            installURL: URL(filePath: "/tmp/dxmt"),
            capabilities: [.dxmt, .dxmtBridge]
        )
        let registry = CapabilityRegistry(
            host: host,
            engine: engine,
            components: [component],
            bridgeAvailability: .unavailable("ABI handshake failed.")
        )

        XCTAssertFalse(registry.supports(.dxmtBridge))
        XCTAssertEqual(registry.status(of: .dxmtBridge).reason, "ABI handshake failed.")
        XCTAssertFalse(registry.supportedGraphicsBackends().contains(.dxmt))
    }

    func testResolvesWineRuntimeInsideMacOSApplicationBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "StillBridgeBundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appending(path: "Wine Staging.app/Contents")
        let wrapper = contents.appending(path: "MacOS/wine")
        let runtime = contents.appending(path: "Resources/wine")
        try FileManager.default.createDirectory(
            at: wrapper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true
        )
        try Data().write(to: wrapper)

        XCTAssertEqual(
            DXMTBridgeValidator().runtimeRoot(for: wrapper).standardizedFileURL.path,
            runtime.standardizedFileURL.path
        )
    }
}
