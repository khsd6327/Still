import Foundation
import XCTest
@testable import StillCore

final class StillStoreMigrationTests: XCTestCase {
    func testMigratesLegacyBottleAndPinWithStableIdentity() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bottleID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let createdAt = Date(timeIntervalSinceReferenceDate: 1234)
        let bottle = Bottle(
            id: bottleID,
            name: "Legacy",
            prefixURL: root.appending(path: "Bottles/Legacy"),
            engineID: "wine-staging-11.14",
            recipeID: "steam",
            graphicsBackend: .dxmt,
            windowsVersion: .windows11,
            enhancedSync: .msync,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let executableURL = bottle.prefixURL.appending(
            path: "drive_c/Program Files/Test/Test.exe"
        )
        let legacyApplication = InstalledWindowsApplication(
            id: "pin-test.exe",
            name: "Test",
            source: .pinned,
            sourceIdentifier: "drive_c/Program Files/Test/Test.exe",
            installState: .installed,
            installDirectoryURL: executableURL.deletingLastPathComponent(),
            launcherURL: executableURL,
            launchArguments: ["--safe"]
        )

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try legacyBottleData(bottle).write(
            to: root.appending(path: "bottles.json")
        )
        try legacyPinData(
            bottleID: bottleID,
            application: legacyApplication
        ).write(to: root.appending(path: "application-pins.json"))

        let store = JSONStillStore(rootURL: root)
        let first = try await store.load()
        let second = try await store.load()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.schemaVersion, 2)
        XCTAssertEqual(first.environments.count, 1)
        XCTAssertEqual(first.environments[0].id, bottleID)
        XCTAssertEqual(first.environments[0].name, "Legacy")
        XCTAssertEqual(first.environments[0].pinnedEngineBuildID, "wine-staging-11.14")
        XCTAssertEqual(first.applications.count, 1)
        XCTAssertEqual(first.launchEntries.count, 1)
        XCTAssertEqual(first.applications[0].launchEntryIDs, [first.launchEntries[0].id])
        XCTAssertEqual(first.launchEntries[0].arguments, ["--safe"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appending(
                    path: "Migration Backups/schema-1/bottles.json"
                ).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appending(
                    path: "Migration Backups/schema-1/application-pins.json"
                ).path
            )
        )
    }

    func testMigrationIdentityDoesNotDependOnExecutablePath() throws {
        let migrator = StillStoreMigrator()
        let bottleID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let bottle = Bottle(
            id: bottleID,
            name: "Legacy",
            prefixURL: URL(filePath: "/tmp/legacy")
        )
        let first = application(
            id: "pin-stable",
            executableURL: URL(filePath: "/tmp/legacy/drive_c/One.exe")
        )
        let moved = application(
            id: "pin-stable",
            executableURL: URL(filePath: "/tmp/legacy/drive_c/Moved/One.exe")
        )

        let firstDocument = try migrator.migrate(
            bottlesData: legacyBottleData(bottle),
            pinsData: legacyPinData(bottleID: bottleID, application: first)
        )
        let movedDocument = try migrator.migrate(
            bottlesData: legacyBottleData(bottle),
            pinsData: legacyPinData(bottleID: bottleID, application: moved)
        )

        XCTAssertEqual(firstDocument.applications[0].id, movedDocument.applications[0].id)
        XCTAssertNotEqual(
            firstDocument.launchEntries[0].executableURL,
            movedDocument.launchEntries[0].executableURL
        )
    }

    func testRejectsTwoEnvironmentsWithTheSameCanonicalPrefix() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix")
        let store = JSONStillStore(rootURL: root)
        try await store.saveEnvironment(
            WindowsEnvironment(name: "First", prefixURL: prefix)
        )

        do {
            try await store.saveEnvironment(
                WindowsEnvironment(
                    name: "Second",
                    prefixURL: prefix.appending(path: "..", directoryHint: .isDirectory)
                        .appending(path: "Prefix")
                )
            )
            XCTFail("Expected duplicate canonical prefix rejection")
        } catch let error as StillCoreError {
            guard case .invalidStore(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("canonical Environment prefix"))
        }
    }

    func testRemovingApplicationAlsoRemovesItsOperations() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = WindowsEnvironment(
            name: "Test",
            prefixURL: root.appending(path: "Prefix")
        )
        let applicationID = UUID()
        let entry = LaunchEntry(
            applicationID: applicationID,
            executableURL: environment.prefixURL.appending(path: "drive_c/App/app.exe")
        )
        let application = LibraryApplication(
            id: applicationID,
            environmentID: environment.id,
            name: "App",
            launchEntryIDs: [entry.id]
        )
        let store = JSONStillStore(rootURL: root)
        try await store.saveEnvironment(environment)
        try await store.saveApplication(application, launchEntries: [entry])
        try await store.saveOperation(StillOperation(
            kind: .launchApplication,
            environmentID: environment.id,
            applicationID: applicationID
        ))

        try await store.removeApplicationFromLibrary(id: applicationID)
        let document = try await store.load()

        XCTAssertTrue(document.applications.isEmpty)
        XCTAssertTrue(document.launchEntries.isEmpty)
        XCTAssertTrue(document.operations.isEmpty)
    }

    func testUnsupportedLegacySchemaDoesNotCreateNewStore() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyURL = root.appending(path: "bottles.json")
        try Data("{\"schemaVersion\":99,\"bottles\":[]}".utf8).write(to: legacyURL)

        let store = JSONStillStore(rootURL: root)
        do {
            _ = try await store.load()
            XCTFail("Expected unsupported schema failure.")
        } catch let error as StillCoreError {
            guard case .unsupportedSchema(99) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appending(path: "store.json").path)
        )
    }

    func testRejectsOrphanedLegacyPinWithoutDroppingData() throws {
        let migrator = StillStoreMigrator()
        let bottle = Bottle(
            id: UUID(),
            name: "Present",
            prefixURL: URL(filePath: "/tmp/present")
        )
        let missingBottleID = UUID()
        let application = application(
            id: "pin-orphan",
            executableURL: URL(filePath: "/tmp/missing/Orphan.exe")
        )

        XCTAssertThrowsError(
            try migrator.migrate(
                bottlesData: legacyBottleData(bottle),
                pinsData: legacyPinData(
                    bottleID: missingBottleID,
                    application: application
                )
            )
        ) { error in
            guard case StillCoreError.invalidStore = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testStoresApplicationsWithoutUsingPathsAsIdentity() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONStillStore(rootURL: root)
        let environment = WindowsEnvironment(
            name: "Managed",
            prefixURL: root.appending(path: "Environments/Managed")
        )
        try await store.saveEnvironment(environment)

        let applicationID = UUID()
        var application = LibraryApplication(
            id: applicationID,
            environmentID: environment.id,
            name: "Movable"
        )
        let entryID = UUID()
        application.launchEntryIDs = [entryID]
        var entry = LaunchEntry(
            id: entryID,
            applicationID: applicationID,
            executableURL: environment.prefixURL.appending(path: "One.exe")
        )
        try await store.saveApplication(application, launchEntries: [entry])

        entry.executableURL = environment.prefixURL.appending(path: "Moved/One.exe")
        try await store.saveApplication(application, launchEntries: [entry])
        let reloaded = try await store.applications(environmentID: environment.id)
        let document = try await store.load()

        XCTAssertEqual(reloaded.map(\.id), [applicationID])
        XCTAssertEqual(document.launchEntries, [entry])
    }

    func testDiscoveryReconciliationRemovesOnlyMissingProviderItems() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONStillStore(rootURL: root)
        let environment = WindowsEnvironment(
            name: "Steam",
            prefixURL: root.appending(path: "Environments/Steam")
        )
        try await store.saveEnvironment(environment)

        let generation = UUID()
        let retainedID = UUID()
        let retainedEntryID = UUID()
        let retained = LibraryApplication(
            id: retainedID,
            environmentID: environment.id,
            name: "Retained",
            providerID: "steam",
            providerItemID: "100",
            launchEntryIDs: [retainedEntryID],
            selectedProfileID: "user-selected",
            isFavorite: true,
            lastDiscoveryGeneration: generation
        )
        try await store.saveApplication(retained, launchEntries: [
            LaunchEntry(
                id: retainedEntryID,
                applicationID: retainedID,
                executableURL: environment.prefixURL.appending(path: "steam.exe"),
                arguments: ["-applaunch", "100"]
            )
        ])

        let staleID = UUID()
        let staleEntryID = UUID()
        let stale = LibraryApplication(
            id: staleID,
            environmentID: environment.id,
            name: "Stale",
            providerID: "steam",
            providerItemID: "200",
            launchEntryIDs: [staleEntryID]
        )
        try await store.saveApplication(stale, launchEntries: [
            LaunchEntry(
                id: staleEntryID,
                applicationID: staleID,
                executableURL: environment.prefixURL.appending(path: "steam.exe"),
                arguments: ["-applaunch", "200"]
            )
        ])

        let removed = try await store.reconcileDiscoveredApplications(
            environmentID: environment.id,
            providerID: "steam",
            discoveredProviderItemIDs: ["100"]
        )
        let document = try await store.load()

        XCTAssertEqual(removed, [staleID])
        XCTAssertEqual(document.applications.map(\.id), [retainedID])
        XCTAssertEqual(document.applications.first?.selectedProfileID, "user-selected")
        XCTAssertEqual(document.applications.first?.lastDiscoveryGeneration, generation)
        XCTAssertTrue(document.applications.first?.isFavorite == true)
        XCTAssertEqual(document.launchEntries.map(\.id), [retainedEntryID])
    }

    func testRemovingEnvironmentRecordLeavesPrefixAndRemovesRelatedRecords() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "External Prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let marker = prefix.appending(path: "user.reg")
        try Data("external".utf8).write(to: marker)

        let store = JSONStillStore(rootURL: root.appending(path: "Store"))
        let environment = WindowsEnvironment(name: "External", prefixURL: prefix)
        try await store.saveEnvironment(environment)

        let applicationID = UUID()
        let entryID = UUID()
        let application = LibraryApplication(
            id: applicationID,
            environmentID: environment.id,
            name: "Example",
            launchEntryIDs: [entryID]
        )
        let entry = LaunchEntry(
            id: entryID,
            applicationID: applicationID,
            executableURL: prefix.appending(path: "drive_c/Example.exe")
        )
        try await store.saveApplication(application, launchEntries: [entry])
        var operation = StillOperation(
            kind: .launchInstaller,
            environmentID: environment.id
        )
        try operation.transition(to: .running)
        try operation.transition(to: .succeeded, resultSummary: "Installer launched")
        try await store.saveOperation(operation)

        try await store.deleteEnvironmentRecord(id: environment.id)

        let document = try await store.load()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(document.environments.isEmpty)
        XCTAssertTrue(document.applications.isEmpty)
        XCTAssertTrue(document.launchEntries.isEmpty)
        XCTAssertTrue(document.operations.isEmpty)
    }

    func testConcurrentStoreInstancesRejectLostUpdate() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = JSONStillStore(rootURL: root)
        let secondStore = JSONStillStore(rootURL: root)
        var firstDocument = try await firstStore.load()
        var staleDocument = try await secondStore.load()

        firstDocument.environments.append(WindowsEnvironment(
            name: "First",
            prefixURL: root.appending(path: "First")
        ))
        try await firstStore.save(firstDocument)

        staleDocument.environments.append(WindowsEnvironment(
            name: "Stale",
            prefixURL: root.appending(path: "Stale")
        ))
        do {
            try await secondStore.save(staleDocument)
            XCTFail("Expected a concurrent store modification failure.")
        } catch let error as StillCoreError {
            guard case .concurrentStoreModification = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let reloaded = try await firstStore.load()
        XCTAssertEqual(reloaded.environments.map(\.name), ["First"])
        XCTAssertGreaterThan(reloaded.revision, staleDocument.revision)
    }

    func testMissingStoreIdentifierIsPersistedOnLoad() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appending(path: "store.json")
        let document = StillStoreDocument()
        let encoded = try JSONEncoder().encode(document)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "storeIdentifier")
        try JSONSerialization.data(withJSONObject: object).write(to: storeURL)

        let store = JSONStillStore(rootURL: root)
        let first = try await store.load()
        let second = try await store.load()
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeURL))
                as? [String: Any]
        )

        XCTAssertEqual(first.storeIdentifier, second.storeIdentifier)
        XCTAssertEqual(persisted["storeIdentifier"] as? String, first.storeIdentifier.uuidString)
    }

    func testCorruptStoreIsPreservedWithoutOverwrite() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appending(path: "store.json")
        let corruptData = Data("{not-json".utf8)
        try corruptData.write(to: storeURL)
        let store = JSONStillStore(rootURL: root)

        do {
            _ = try await store.load()
            XCTFail("Expected corrupt store failure.")
        } catch {
            // The original bytes must remain available for recovery.
        }

        XCTAssertEqual(try Data(contentsOf: storeURL), corruptData)
        let preserved = try FileManager.default.contentsOfDirectory(
            at: root.appending(path: "Corrupt Stores"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: preserved[0]), corruptData)
    }

    func testRejectsDocumentWithBrokenRelationshipsBeforeWriting() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONStillStore(rootURL: root)
        let orphan = LibraryApplication(
            environmentID: UUID(),
            name: "Orphan"
        )

        do {
            try await store.save(StillStoreDocument(applications: [orphan]))
            XCTFail("Expected relationship validation failure.")
        } catch let error as StillCoreError {
            guard case .invalidStore = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appending(path: "store.json").path)
        )
    }

    private func application(
        id: String,
        executableURL: URL
    ) -> InstalledWindowsApplication {
        InstalledWindowsApplication(
            id: id,
            name: "Stable",
            source: .pinned,
            installState: .installed,
            installDirectoryURL: executableURL.deletingLastPathComponent(),
            launcherURL: executableURL
        )
    }

    private func legacyBottleData(_ bottle: Bottle) throws -> Data {
        struct Document: Encodable {
            let schemaVersion: Int
            let bottles: [Bottle]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(
                String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
            )
        }
        return try encoder.encode(Document(schemaVersion: 1, bottles: [bottle]))
    }

    private func legacyPinData(
        bottleID: Bottle.ID,
        application: InstalledWindowsApplication
    ) throws -> Data {
        struct Pin: Encodable {
            let bottleID: Bottle.ID
            let application: InstalledWindowsApplication
        }
        struct Document: Encodable {
            let schemaVersion: Int
            let pins: [Pin]
        }
        return try JSONEncoder().encode(
            Document(
                schemaVersion: 1,
                pins: [Pin(bottleID: bottleID, application: application)]
            )
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "StillStoreMigrationTests-\(UUID().uuidString)")
    }
}
