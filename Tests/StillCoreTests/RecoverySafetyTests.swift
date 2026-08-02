import Foundation
import XCTest
@testable import StillCore

final class RecoverySafetyTests: XCTestCase {
    func testRestorePointRequiresStoppedEnvironmentAndNeverAutoDeletesAtLimit() async throws {
        let root = temporaryRoot("RestorePoint")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix")
        try write("registry", to: prefix.appending(path: "system.reg"))
        let environment = WindowsEnvironment(name: "Game", prefixURL: prefix, pinnedEngineBuildID: "engine-1")
        let service = RestorePointService(rootURL: root.appending(path: "Points"))
        var active = LaunchSession(environmentID: environment.id)
        try active.transition(to: .launching)
        try active.transition(to: .running, rootProcessIdentifier: 10)

        do {
            _ = try await service.create(
                environment: environment,
                applications: [],
                launchEntries: [],
                activeSessions: [active]
            )
            XCTFail("Expected running Environment rejection")
        } catch let error as StillCoreError {
            XCTAssertEqual(error, .environmentMustBeStopped(environment.id))
        }

        let point = try await service.create(
            environment: environment,
            applications: [],
            launchEntries: [],
            activeSessions: [],
            limit: 1
        )
        XCTAssertEqual(point.fileCount, 1)
        XCTAssertEqual(point.requiredEngineBuildID, "engine-1")
        do {
            _ = try await service.create(
                environment: environment,
                applications: [],
                launchEntries: [],
                activeSessions: [],
                limit: 1
            )
            XCTFail("Expected cleanup confirmation boundary")
        } catch let error as StillCoreError {
            XCTAssertEqual(error, .restorePointLimitReached(1))
        }
        let retainedCount = try await service.manifests(environmentID: environment.id).count
        XCTAssertEqual(retainedCount, 1)
    }

    func testStandardBackupExcludesSensitiveDataAndEngineBinaries() async throws {
        let root = temporaryRoot("Backup")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix")
        try write("game", to: prefix.appending(path: "drive_c/Program Files/Game/game.exe"))
        try write("cookie", to: prefix.appending(path: "drive_c/users/test/AppData/Cookies"))
        try write("document", to: prefix.appending(path: "drive_c/users/test/Documents/private.txt"))
        let engineURL = root.appending(path: "Engines/engine/bin/wine")
        try write("engine", to: engineURL)
        let environment = WindowsEnvironment(
            name: "Game",
            prefixURL: prefix,
            pinnedEngineBuildID: "engine-1"
        )
        let backupURL = root.appending(path: "Game.stillbackup")
        let service = BackupService()
        let preview = try await service.preview(
            environment: environment,
            applications: [],
            launchEntries: [],
            components: [],
            destinationURL: backupURL,
            encrypted: false
        )
        XCTAssertEqual(preview.manifest.fileCount, 1)
        try await service.create(preview: preview, activeSessions: [])

        let restored = root.appending(path: "Restored")
        let manifest = try await service.restore(
            backupURL: backupURL,
            destinationPrefixURL: restored
        )
        XCTAssertEqual(manifest.requiredEngineBuildID, "engine-1")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: restored.appending(path: "drive_c/Program Files/Game/game.exe").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: restored.appending(path: "drive_c/users/test/AppData/Cookies").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: restored.appending(path: "Engines/engine/bin/wine").path
        ))
    }

    func testEncryptedBackupRequiresCorrectPassword() async throws {
        let root = temporaryRoot("EncryptedBackup")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix")
        try write("app", to: prefix.appending(path: "drive_c/app.exe"))
        let environment = WindowsEnvironment(name: "App", prefixURL: prefix)
        let backupURL = root.appending(path: "App.stillbackup")
        let service = BackupService()
        let preview = try await service.preview(
            environment: environment,
            applications: [],
            launchEntries: [],
            components: [],
            destinationURL: backupURL,
            encrypted: true
        )
        try await service.create(
            preview: preview,
            password: "correct horse battery staple",
            activeSessions: []
        )

        do {
            _ = try await service.inspectBackup(at: backupURL)
            XCTFail("Expected password requirement")
        } catch let error as StillCoreError {
            XCTAssertEqual(error, .backupPasswordRequired)
        }
        do {
            _ = try await service.inspectBackup(at: backupURL, password: "wrong")
            XCTFail("Expected decryption failure")
        } catch let error as StillCoreError {
            XCTAssertEqual(error, .backupDecryptionFailed)
        }
        let manifest = try await service.inspectBackup(
            at: backupURL,
            password: "correct horse battery staple"
        )
        XCTAssertEqual(manifest.environment.id, environment.id)
    }

    func testBackupStreamsLargeFilesAndVerifiesRestoredBytes() async throws {
        let root = temporaryRoot("StreamingBackup")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix")
        let sourceURL = prefix.appending(path: "drive_c/Game/content.bin")
        let sourceData = Data((0 ..< 2_500_000).map { UInt8($0 % 251) })
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try sourceData.write(to: sourceURL)
        let environment = WindowsEnvironment(name: "Game", prefixURL: prefix)
        let backupURL = root.appending(path: "Game.stillbackup")
        let service = BackupService()
        let preview = try await service.preview(
            environment: environment,
            applications: [],
            launchEntries: [],
            components: [],
            destinationURL: backupURL,
            encrypted: false
        )

        try await service.create(preview: preview, activeSessions: [])

        let prefixBytes = try FileHandle(forReadingFrom: backupURL).read(upToCount: 8)
        XCTAssertEqual(prefixBytes, Data("STILLBK2".utf8))
        let restored = root.appending(path: "Restored")
        _ = try await service.restore(
            backupURL: backupURL,
            destinationPrefixURL: restored
        )
        XCTAssertEqual(
            try SHA256Verifier.digest(of: sourceURL),
            try SHA256Verifier.digest(
                of: restored.appending(path: "drive_c/Game/content.bin")
            )
        )
    }

    func testEncryptedBackupRecordsVersionedKDFAndRejectsTampering() async throws {
        let root = temporaryRoot("TamperedBackup")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix")
        try write("protected", to: prefix.appending(path: "drive_c/app.exe"))
        let environment = WindowsEnvironment(name: "App", prefixURL: prefix)
        let backupURL = root.appending(path: "App.stillbackup")
        let service = BackupService()
        let preview = try await service.preview(
            environment: environment,
            applications: [],
            launchEntries: [],
            components: [],
            destinationURL: backupURL,
            encrypted: true
        )
        try await service.create(
            preview: preview,
            password: "password",
            activeSessions: []
        )
        var bytes = try Data(contentsOf: backupURL)
        XCTAssertNotNil(bytes.range(of: Data("pbkdf2-hmac-sha256".utf8)))
        bytes[bytes.count - 8] ^= 0xff
        try bytes.write(to: backupURL)

        do {
            _ = try await service.restore(
                backupURL: backupURL,
                destinationPrefixURL: root.appending(path: "Restored"),
                password: "password"
            )
            XCTFail("Expected authenticated-frame failure")
        } catch let error as StillCoreError {
            XCTAssertEqual(error, .backupDecryptionFailed)
        }
    }

    func testEncryptedBackupFailsWhenSecureRandomGenerationFails() async throws {
        let root = temporaryRoot("RandomFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix")
        try write("app", to: prefix.appending(path: "drive_c/app.exe"))
        let environment = WindowsEnvironment(name: "App", prefixURL: prefix)
        let backupURL = root.appending(path: "App.stillbackup")
        let service = BackupService { _ in
            throw StillCoreError.verificationFailed("Random source failed.")
        }
        let preview = try await service.preview(
            environment: environment,
            applications: [],
            launchEntries: [],
            components: [],
            destinationURL: backupURL,
            encrypted: true
        )

        do {
            try await service.create(
                preview: preview,
                password: "password",
                activeSessions: []
            )
            XCTFail("Expected secure random failure")
        } catch let error as StillCoreError {
            guard case .verificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testLegacyBackupRemainsReadable() async throws {
        let root = temporaryRoot("LegacyBackup")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let environment = WindowsEnvironment(
            name: "Legacy",
            prefixURL: root.appending(path: "Original")
        )
        let manifest = BackupManifest(
            formatVersion: 1,
            createdAt: .now,
            environment: environment,
            snapshot: ConfigurationSnapshot(
                environment: environment,
                applications: [],
                launchEntries: []
            ),
            requiredEngineBuildID: nil,
            requiredComponents: [:],
            excludedCategories: [],
            fileCount: 1,
            byteCount: 6
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(LegacyTestPayload(
            manifest: manifest,
            files: [
                LegacyTestFileRecord(
                    relativePath: "drive_c/legacy.txt",
                    permissions: 0o644,
                    data: Data("legacy".utf8)
                )
            ]
        ))
        let backupURL = root.appending(path: "Legacy.stillbackup")
        try encoder.encode(LegacyTestEnvelope(
            envelopeVersion: 1,
            isEncrypted: false,
            salt: nil,
            payload: payload,
            sealedPayload: nil
        )).write(to: backupURL)
        let service = BackupService()

        let inspected = try await service.inspectBackup(at: backupURL)
        XCTAssertEqual(inspected.formatVersion, 1)
        XCTAssertEqual(inspected.environment.id, environment.id)
        XCTAssertEqual(inspected.fileCount, 1)
        XCTAssertEqual(inspected.byteCount, 6)
        let restored = root.appending(path: "Restored")
        _ = try await service.restore(
            backupURL: backupURL,
            destinationPrefixURL: restored
        )
        XCTAssertEqual(
            try String(
                contentsOf: restored.appending(path: "drive_c/legacy.txt"),
                encoding: .utf8
            ),
            "legacy"
        )
    }

    func testDuplicateCreatesIndependentIdentityAndVerifiedFiles() throws {
        let root = temporaryRoot("Duplicate")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Source")
        try write("data", to: source.appending(path: "system.reg"))
        let environment = WindowsEnvironment(name: "Source", prefixURL: source)

        let duplicate = try EnvironmentRecoveryService().duplicate(
            environment,
            name: "Copy",
            managedRootURL: root.appending(path: "Managed"),
            activeSessions: []
        )
        XCTAssertNotEqual(duplicate.id, environment.id)
        XCTAssertEqual(
            try String(
                contentsOf: duplicate.prefixURL.appending(path: "system.reg"),
                encoding: .utf8
            ),
            "data"
        )
    }

    func testRepairInspectsBeforeApplyingAndRequiresRestorePoint() throws {
        let root = temporaryRoot("Repair")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = WindowsEnvironment(
            name: "Broken",
            prefixURL: root.appending(path: "Missing"),
            pinnedEngineBuildID: "missing"
        )
        let report = RepairService().inspect(
            environment: environment,
            engineBuilds: [],
            components: [],
            profile: nil,
            launchEntries: []
        )
        XCTAssertEqual(report.issues.count, 2)
        XCTAssertFalse(report.isHealthy)
        XCTAssertThrowsError(try RepairService().applyFileRepairs(
            [.createPrefixDirectory],
            environment: environment,
            launchEntries: [],
            activeSessions: [],
            restorePointCreated: false
        ))
        _ = try RepairService().applyFileRepairs(
            [.createPrefixDirectory],
            environment: environment,
            launchEntries: [],
            activeSessions: [],
            restorePointCreated: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.prefixURL.path))
    }

    func testLogRotationUsesConfiguredRetention() throws {
        let root = temporaryRoot("Logs")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appending(path: "old.log")
        let recent = root.appending(path: "recent.log")
        try write("old", to: old)
        try write("new", to: recent)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10 * 86_400)],
            ofItemAtPath: old.path
        )
        let removed = try LogRotationService().rotate(
            rootURL: root,
            retentionDays: 7,
            now: now
        )
        XCTAssertEqual(removed.map(\.lastPathComponent), ["old.log"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testVerifiedCopyPreservesWineDriveSymlinksWithoutResolvingOutsidePrefix() throws {
        let source = temporaryRoot("WineSymlinkSource")
        let destination = temporaryRoot("WineSymlinkDestination")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try write("registry", to: source.appending(path: "system.reg"))
        let dosdevices = source.appending(path: "dosdevices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: dosdevices,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: dosdevices.appending(path: "z:"),
            withDestinationURL: URL(filePath: "/")
        )

        _ = try FileTreeServices.verifiedCopy(from: source, to: destination)

        let copiedLink = destination.appending(path: "dosdevices/z:")
        let values = try copiedLink.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: copiedLink.path),
            "/"
        )
    }

    private func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "Still\(name)Tests")
            .appending(path: UUID().uuidString)
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }
}

private struct LegacyTestFileRecord: Codable {
    let relativePath: String
    let permissions: Int
    let data: Data
}

private struct LegacyTestPayload: Codable {
    let manifest: BackupManifest
    let files: [LegacyTestFileRecord]
}

private struct LegacyTestEnvelope: Codable {
    let envelopeVersion: Int
    let isEncrypted: Bool
    let salt: Data?
    let payload: Data?
    let sealedPayload: Data?
}
