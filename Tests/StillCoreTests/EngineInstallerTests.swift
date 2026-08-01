import Foundation
import XCTest
@testable import StillCore

final class EngineInstallerTests: XCTestCase {
    func testBundledCatalogHasPinnedChecksums() {
        XCTAssertEqual(BundledEngineCatalog.manifests.count, 4)
        for manifest in BundledEngineCatalog.manifests {
            XCTAssertEqual(manifest.sha256.count, 64)
            XCTAssertGreaterThan(manifest.downloadSize, 0)
            XCTAssertEqual(manifest.downloadURL.scheme, "https")
        }
    }

    func testInstallsVerifiedTarXZArchive() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appending(path: "StillEngineInstallerTests")
            .appending(path: UUID().uuidString)
        defer { try? fileManager.removeItem(at: rootURL) }

        let sourceURL = rootURL.appending(path: "source")
        let appURL = sourceURL.appending(path: "Wine Test.app")
        let binaryURL = appURL.appending(path: "Contents/Resources/wine/bin/wine")
        try fileManager.createDirectory(
            at: binaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binaryURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binaryURL.path
        )

        let archiveURL = rootURL.appending(path: "wine-test.tar.xz")
        try makeArchive(
            sourceURL: sourceURL,
            archiveURL: archiveURL,
            itemName: "Wine Test.app"
        )

        let manifest = EngineManifest(
            id: "wine-test",
            family: .wineStable,
            displayName: "Wine Test",
            version: "1",
            sourceURL: URL(string: "https://example.com/source")!,
            downloadURL: URL(string: "https://example.com/wine-test.tar.xz")!,
            sha256: try SHA256Verifier.digest(of: archiveURL),
            downloadSize: Int64(
                try fileManager.attributesOfItem(atPath: archiveURL.path)[.size]
                    as? Int ?? 0
            ),
            archiveRoot: "Wine Test.app",
            wineBinaryRelativePath: "Contents/Resources/wine/bin/wine",
            capabilities: [.win64]
        )
        let installRootURL = rootURL.appending(path: "installed")
        let installer = EngineInstaller(rootURL: installRootURL)

        let descriptor = try await installer.installDownloadedArchive(
            manifest,
            archiveURL: archiveURL
        )

        XCTAssertEqual(descriptor.id, manifest.id)
        XCTAssertTrue(
            fileManager.isExecutableFile(atPath: descriptor.wineBinaryURL.path)
        )
        let installedAgain = await installer.installedDescriptor(for: manifest)
        XCTAssertEqual(installedAgain, descriptor)
    }

    func testRejectsChecksumMismatch() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("Still".utf8).write(to: fileURL)

        XCTAssertThrowsError(
            try SHA256Verifier.verify(
                fileURL: fileURL,
                expectedDigest: String(repeating: "0", count: 64)
            )
        ) { error in
            guard case StillCoreError.checksumMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDiscoversLocallyBuiltEngineFromVersionedManifest() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appending(path: "StillLocalEngineTests")
            .appending(path: UUID().uuidString)
        defer { try? fileManager.removeItem(at: rootURL) }

        let versionURL = rootURL
            .appending(path: "still-dxmt", directoryHint: .isDirectory)
            .appending(path: "11.14", directoryHint: .isDirectory)
        let binaryURL = versionURL.appending(
            path: "Wine Staging.app/Contents/Resources/wine/bin/wine"
        )
        try fileManager.createDirectory(
            at: binaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binaryURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binaryURL.path
        )
        let manifest = InstalledEngineBuildManifest(
            id: "still-dxmt",
            family: .wineStaging,
            displayName: "Still DXMT",
            version: "11.14",
            archiveRoot: "Wine Staging.app",
            wineBinaryRelativePath: "Contents/Resources/wine/bin/wine",
            capabilities: [.win64, .esync, .dxmt]
        )
        try JSONEncoder().encode(manifest).write(
            to: versionURL.appending(path: InstalledEngineBuildManifest.fileName)
        )

        let descriptors = await EngineInstaller(rootURL: rootURL).installedDescriptors()

        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors[0].id, "still-dxmt")
        XCTAssertEqual(descriptors[0].family, .wineStaging)
        XCTAssertTrue(descriptors[0].capabilities.contains(.dxmt))
        XCTAssertEqual(
            descriptors[0].wineBinaryURL.resolvingSymlinksInPath(),
            binaryURL.resolvingSymlinksInPath()
        )
    }

    func testGPTKRequiresExternalLicenseAcceptance() async {
        let manifest = try! BundledEngineCatalog.manifest(
            id: "gcenx-gptk-3.0-3"
        )
        let installer = EngineInstaller()

        do {
            _ = try await installer.install(manifest)
            XCTFail("Expected license acceptance failure.")
        } catch {
            XCTAssertEqual(
                error as? StillCoreError,
                .externalLicenseAcceptanceRequired(manifest.id)
            )
        }
    }

    private func makeArchive(
        sourceURL: URL,
        archiveURL: URL,
        itemName: String
    ) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = [
            "-cJf", archiveURL.path,
            "-C", sourceURL.path,
            itemName
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
