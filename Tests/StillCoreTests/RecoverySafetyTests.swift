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

    func testPermanentDeletionAlwaysRequiresFinalConfirmation() throws {
        let root = temporaryRoot("Delete")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix")
        try write("data", to: prefix.appending(path: "file.txt"))
        let environment = WindowsEnvironment(name: "Delete", prefixURL: prefix)
        let service = EnvironmentRecoveryService()
        let preview = try service.deletionPreview(environment: environment, applications: [])

        XCTAssertThrowsError(try service.delete(
            preview: preview,
            method: .permanentlyDelete,
            activeSessions: [],
            finalPermanentConfirmation: false
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.path))
        _ = try service.delete(
            preview: preview,
            method: .permanentlyDelete,
            activeSessions: [],
            finalPermanentConfirmation: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.path))
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
