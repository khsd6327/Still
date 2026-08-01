import Foundation
import XCTest
@testable import StillCore

final class EnvironmentRestoreCoordinatorTests: XCTestCase {
    func testRestoreCommitsManagedPrefixAndLibraryRelationshipsTogether() async throws {
        let fixture = try await makeFixture("Commit")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourcePrefix = fixture.root.appending(path: "Source")
        let executableURL = sourcePrefix.appending(path: "drive_c/Game/game.exe")
        try write("game", to: executableURL)
        let sourceEnvironment = WindowsEnvironment(
            name: "Game",
            prefixURL: sourcePrefix
        )
        let sourceApplicationID = UUID()
        let sourceEntry = LaunchEntry(
            applicationID: sourceApplicationID,
            executableURL: executableURL,
            arguments: ["--safe"],
            workingDirectoryURL: executableURL.deletingLastPathComponent()
        )
        let sourceApplication = LibraryApplication(
            id: sourceApplicationID,
            environmentID: sourceEnvironment.id,
            name: "Game",
            category: .game,
            providerID: "provider",
            providerItemID: "100",
            launchEntryIDs: [sourceEntry.id],
            selectedProfileID: "profile",
            isFavorite: true,
            providerManagedState: .installed
        )
        let backupURL = fixture.root.appending(path: "Game.stillbackup")
        let preview = try await fixture.backupService.preview(
            environment: sourceEnvironment,
            applications: [sourceApplication],
            launchEntries: [sourceEntry],
            components: [],
            destinationURL: backupURL,
            encrypted: false
        )
        try await fixture.backupService.create(preview: preview, activeSessions: [])

        let restored = try await fixture.coordinator.restore(backupURL: backupURL)
        let document = try await fixture.store.load()

        XCTAssertEqual(document.environments, [restored])
        XCTAssertEqual(document.applications.count, 1)
        XCTAssertEqual(document.launchEntries.count, 1)
        XCTAssertEqual(document.applications[0].environmentID, restored.id)
        XCTAssertEqual(document.applications[0].launchEntryIDs, [document.launchEntries[0].id])
        XCTAssertEqual(document.applications[0].providerManagedState, .installed)
        XCTAssertNil(document.applications[0].lastLaunchedAt)
        XCTAssertTrue(document.applications[0].isFavorite)
        XCTAssertEqual(document.launchEntries[0].arguments, ["--safe"])
        XCTAssertTrue(
            document.launchEntries[0].executableURL.path.hasPrefix(
                restored.prefixURL.path + "/"
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: restored.prefixURL.appending(path: "drive_c/Game/game.exe"),
                encoding: .utf8
            ),
            "game"
        )
        try fixture.ownershipService.validateManagedOwnership(
            of: restored,
            storeIdentifier: document.storeIdentifier
        )
    }

    func testStoreCommitFailureRollsBackPrefixAndJournal() async throws {
        let root = temporaryRoot("Rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeRoot = root.appending(path: "Store")
        let store = JSONStillStore(rootURL: storeRoot)
        _ = try await store.load()
        let backupService = BackupService()
        let ownershipService = EnvironmentOwnershipService(
            managedRootURL: storeRoot.appending(path: "Environments")
        )
        let coordinator = EnvironmentRestoreCoordinator(
            store: store,
            backupService: backupService,
            ownershipService: ownershipService,
            rootURL: storeRoot,
            beforeStoreCommit: { throw RestoreTestFailure.injected }
        )
        let sourcePrefix = root.appending(path: "Source")
        try write("data", to: sourcePrefix.appending(path: "system.reg"))
        let source = WindowsEnvironment(name: "Source", prefixURL: sourcePrefix)
        let backupURL = root.appending(path: "Source.stillbackup")
        let preview = try await backupService.preview(
            environment: source,
            applications: [],
            launchEntries: [],
            components: [],
            destinationURL: backupURL,
            encrypted: false
        )
        try await backupService.create(preview: preview, activeSessions: [])

        do {
            _ = try await coordinator.restore(backupURL: backupURL)
            XCTFail("Expected the injected store failure.")
        } catch RestoreTestFailure.injected {
        }

        let document = try await store.load()
        XCTAssertTrue(document.environments.isEmpty)
        XCTAssertTrue(try directoryIsEmpty(ownershipService.managedRootURL))
        XCTAssertTrue(try directoryIsEmpty(coordinator.journalRootURL))
        XCTAssertTrue(try directoryIsEmpty(coordinator.stagingRootURL))
    }

    func testRestoreRejectsMissingRequiredEngineBeforeWritingFiles() async throws {
        let fixture = try await makeFixture("MissingEngine")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourcePrefix = fixture.root.appending(path: "Source")
        try write("data", to: sourcePrefix.appending(path: "system.reg"))
        let source = WindowsEnvironment(
            name: "Source",
            prefixURL: sourcePrefix,
            pinnedEngineBuildID: "missing-engine"
        )
        let backupURL = fixture.root.appending(path: "Source.stillbackup")
        let preview = try await fixture.backupService.preview(
            environment: source,
            applications: [],
            launchEntries: [],
            components: [],
            destinationURL: backupURL,
            encrypted: false
        )
        try await fixture.backupService.create(preview: preview, activeSessions: [])

        do {
            _ = try await fixture.coordinator.restore(backupURL: backupURL)
            XCTFail("Expected a missing-engine failure.")
        } catch let error as StillCoreError {
            XCTAssertEqual(error, .engineNotFound("missing-engine"))
        }
        XCTAssertTrue(try directoryIsEmpty(fixture.ownershipService.managedRootURL))
        XCTAssertTrue(try directoryIsEmpty(fixture.coordinator.journalRootURL))
    }

    func testRecoveryRemovesMaterializedPrefixWithoutStoreCommit() async throws {
        let fixture = try await makeFixture("InterruptedRollback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await fixture.store.load()
        let operationID = UUID()
        let environmentID = UUID()
        let nonce = UUID()
        let destination = fixture.ownershipService.managedPrefixURL(for: environmentID)
        let environment = WindowsEnvironment(
            id: environmentID,
            name: "Interrupted",
            prefixURL: destination,
            ownership: .managed,
            managementNonce: nonce
        )
        try fixture.ownershipService.writeMarker(
            for: environment,
            storeIdentifier: document.storeIdentifier
        )
        try write("partial", to: destination.appending(path: "system.reg"))
        let journal = EnvironmentRestoreJournal(
            id: operationID,
            storeIdentifier: document.storeIdentifier,
            environmentID: environmentID,
            managementNonce: nonce,
            stagingPrefixURL: fixture.coordinator.stagingRootURL.appending(
                path: "\(operationID.uuidString)-\(environmentID.uuidString)"
            ),
            destinationPrefixURL: destination,
            applicationIDs: [],
            launchEntryIDs: [],
            state: .prefixMaterialized
        )
        try writeJournal(journal, to: fixture.coordinator.journalRootURL)

        let recoveredCount = try await fixture.coordinator.recoverInterruptedRestores()
        XCTAssertEqual(recoveredCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try directoryIsEmpty(fixture.coordinator.journalRootURL))
    }

    func testRecoveryKeepsCommittedPrefixAndClearsJournal() async throws {
        let fixture = try await makeFixture("InterruptedCommit")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await fixture.store.load()
        let operationID = UUID()
        let environmentID = UUID()
        let nonce = UUID()
        let destination = fixture.ownershipService.managedPrefixURL(for: environmentID)
        let environment = WindowsEnvironment(
            id: environmentID,
            name: "Committed",
            prefixURL: destination,
            ownership: .managed,
            managementNonce: nonce
        )
        try fixture.ownershipService.writeMarker(
            for: environment,
            storeIdentifier: document.storeIdentifier
        )
        try await fixture.store.commitRestoredEnvironment(
            environment,
            applications: [],
            launchEntries: [],
            requiredEngineBuildID: nil,
            requiredComponents: [:],
            expectedStoreIdentifier: document.storeIdentifier
        )
        let journal = EnvironmentRestoreJournal(
            id: operationID,
            storeIdentifier: document.storeIdentifier,
            environmentID: environmentID,
            managementNonce: nonce,
            stagingPrefixURL: fixture.coordinator.stagingRootURL.appending(
                path: "\(operationID.uuidString)-\(environmentID.uuidString)"
            ),
            destinationPrefixURL: destination,
            applicationIDs: [],
            launchEntryIDs: [],
            state: .prefixMaterialized
        )
        try writeJournal(journal, to: fixture.coordinator.journalRootURL)

        let recoveredCount = try await fixture.coordinator.recoverInterruptedRestores()
        XCTAssertEqual(recoveredCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try directoryIsEmpty(fixture.coordinator.journalRootURL))
    }

    private func makeFixture(_ name: String) async throws -> RestoreFixture {
        let root = temporaryRoot(name)
        let storeRoot = root.appending(path: "Store")
        let store = JSONStillStore(rootURL: storeRoot)
        _ = try await store.load()
        let backupService = BackupService()
        let ownershipService = EnvironmentOwnershipService(
            managedRootURL: storeRoot.appending(path: "Environments")
        )
        return RestoreFixture(
            root: root,
            store: store,
            backupService: backupService,
            ownershipService: ownershipService,
            coordinator: EnvironmentRestoreCoordinator(
                store: store,
                backupService: backupService,
                ownershipService: ownershipService,
                rootURL: storeRoot
            )
        )
    }

    private func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "StillRestoreCoordinator\(name)Tests")
            .appending(path: UUID().uuidString)
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }

    private func writeJournal(
        _ journal: EnvironmentRestoreJournal,
        to rootURL: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(journal).write(
            to: rootURL.appending(path: "\(journal.id.uuidString).json")
        )
    }

    private func directoryIsEmpty(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty
    }
}

private struct RestoreFixture {
    let root: URL
    let store: JSONStillStore
    let backupService: BackupService
    let ownershipService: EnvironmentOwnershipService
    let coordinator: EnvironmentRestoreCoordinator
}

private enum RestoreTestFailure: Error {
    case injected
}
