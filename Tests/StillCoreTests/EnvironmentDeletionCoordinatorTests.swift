import Foundation
import XCTest
@testable import StillCore

final class EnvironmentDeletionCoordinatorTests: XCTestCase {
    func testPermanentDeletionRequiresConfirmationThenCommits() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            try await fixture.coordinator.delete(
                environment: fixture.environment,
                method: .permanentlyDelete,
                activeSessions: [],
                finalPermanentConfirmation: false
            )
            XCTFail("Expected permanent deletion confirmation failure.")
        } catch let error as StillCoreError {
            XCTAssertEqual(error, .permanentDeletionConfirmationRequired)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.environment.prefixURL.path))

        try await fixture.coordinator.delete(
            environment: fixture.environment,
            method: .permanentlyDelete,
            activeSessions: [],
            finalPermanentConfirmation: true
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environment.prefixURL.path))
        let deletedDocument = try await fixture.store.load()
        XCTAssertTrue(deletedDocument.environments.isEmpty)
        XCTAssertEqual(try journalCount(fixture.coordinator.journalRootURL), 0)
    }

    func testImportedEnvironmentCannotUsePhysicalDeletion() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeRoot = root.appending(path: "Store")
        let store = JSONStillStore(rootURL: storeRoot)
        let prefix = root.appending(path: "External")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let environment = WindowsEnvironment(
            name: "External",
            prefixURL: prefix,
            ownership: .importedInPlace
        )
        try await store.saveEnvironment(environment)
        let ownership = EnvironmentOwnershipService(
            managedRootURL: storeRoot.appending(path: "Environments")
        )
        let coordinator = EnvironmentDeletionCoordinator(
            store: store,
            ownershipService: ownership,
            rootURL: storeRoot
        )

        await XCTAssertThrowsErrorAsync {
            try await coordinator.delete(
                environment: environment,
                method: .permanentlyDelete,
                activeSessions: [],
                finalPermanentConfirmation: true
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.path))
        let preservedDocument = try await store.load()
        XCTAssertEqual(preservedDocument.environments.map(\.id), [environment.id])
    }

    func testRecoveryRollsQuarantinedFilesBackWhenRecordExists() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operationID = UUID()
        let quarantine = fixture.coordinator.quarantineRootURL.appending(
            path: "\(operationID.uuidString)-\(fixture.environment.id.uuidString)"
        )
        try FileManager.default.createDirectory(
            at: fixture.coordinator.quarantineRootURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: fixture.environment.prefixURL, to: quarantine)
        let document = try await fixture.store.load()
        let journal = EnvironmentDeletionJournal(
            id: operationID,
            storeIdentifier: document.storeIdentifier,
            environmentID: fixture.environment.id,
            managementNonce: try XCTUnwrap(fixture.environment.managementNonce),
            originalPrefixURL: fixture.environment.prefixURL,
            quarantineURL: quarantine,
            method: .permanentlyDelete,
            state: .quarantined
        )
        try write(journal, to: fixture.coordinator.journalRootURL)

        let recoveredCount = try await fixture.coordinator.recoverInterruptedDeletions()
        XCTAssertEqual(recoveredCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.environment.prefixURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertEqual(try journalCount(fixture.coordinator.journalRootURL), 0)
    }

    func testRecoveryFinishesPermanentCleanupAfterStoreCommit() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operationID = UUID()
        let quarantine = fixture.coordinator.quarantineRootURL.appending(
            path: "\(operationID.uuidString)-\(fixture.environment.id.uuidString)"
        )
        try FileManager.default.createDirectory(
            at: fixture.coordinator.quarantineRootURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: fixture.environment.prefixURL, to: quarantine)
        let document = try await fixture.store.load()
        let nonce = try XCTUnwrap(fixture.environment.managementNonce)
        try await fixture.store.commitManagedEnvironmentDeletion(
            id: fixture.environment.id,
            expectedPrefixURL: fixture.environment.prefixURL,
            expectedManagementNonce: nonce
        )
        let journal = EnvironmentDeletionJournal(
            id: operationID,
            storeIdentifier: document.storeIdentifier,
            environmentID: fixture.environment.id,
            managementNonce: nonce,
            originalPrefixURL: fixture.environment.prefixURL,
            quarantineURL: quarantine,
            method: .permanentlyDelete,
            state: .storeCommitted
        )
        try write(journal, to: fixture.coordinator.journalRootURL)

        let recoveredCount = try await fixture.coordinator.recoverInterruptedDeletions()

        XCTAssertEqual(recoveredCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertEqual(try journalCount(fixture.coordinator.journalRootURL), 0)
    }

    private struct Fixture {
        let root: URL
        let store: JSONStillStore
        let coordinator: EnvironmentDeletionCoordinator
        let environment: WindowsEnvironment
    }

    private func makeFixture() async throws -> Fixture {
        let root = temporaryRoot()
        let storeRoot = root.appending(path: "Store")
        let store = JSONStillStore(rootURL: storeRoot)
        let ownership = EnvironmentOwnershipService(
            managedRootURL: storeRoot.appending(path: "Environments")
        )
        let id = UUID()
        let environment = WindowsEnvironment(
            id: id,
            name: "Managed",
            prefixURL: ownership.managedPrefixURL(for: id),
            ownership: .managed,
            managementNonce: UUID()
        )
        let document = try await store.load()
        try ownership.writeMarker(
            for: environment,
            storeIdentifier: document.storeIdentifier
        )
        try Data("payload".utf8).write(
            to: environment.prefixURL.appending(path: "payload.bin")
        )
        try await store.saveEnvironment(environment)
        return Fixture(
            root: root,
            store: store,
            coordinator: EnvironmentDeletionCoordinator(
                store: store,
                ownershipService: ownership,
                rootURL: storeRoot
            ),
            environment: environment
        )
    }

    private func write(_ journal: EnvironmentDeletionJournal, to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(
            to: root.appending(path: "\(journal.id.uuidString).json")
        )
    }

    private func journalCount(_ root: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".json") }.count
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "StillDeletionTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {}
}
