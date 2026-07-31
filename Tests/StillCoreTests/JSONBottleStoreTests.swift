import Foundation
import XCTest
@testable import StillCore

final class JSONBottleStoreTests: XCTestCase {
    func testCreateAndReload() async throws {
        let rootURL = temporaryRoot()
        let store = JSONBottleStore(rootURL: rootURL)
        let created = try await store.create(
            name: "Steam",
            engineID: "winehq-11.10",
            graphicsBackend: .dxmt,
            windowsVersion: .windows11
        )

        let reloaded = try await JSONBottleStore(rootURL: rootURL).bottles()

        XCTAssertEqual(reloaded, [created])
        XCTAssertEqual(reloaded[0].prefixURL.lastPathComponent, created.id.uuidString)
    }

    func testRejectsEmptyName() async throws {
        let store = JSONBottleStore(rootURL: temporaryRoot())
        do {
            _ = try await store.create(name: "   ")
            XCTFail("Expected an invalid bottle name error.")
        } catch let error as StillCoreError {
            XCTAssertEqual(error, .invalidBottleName)
        }
    }

    func testUpdatesEngineWithoutDuplicatingBottle() async throws {
        let rootURL = temporaryRoot()
        let store = JSONBottleStore(rootURL: rootURL)
        var bottle = try await store.create(
            name: "Games",
            engineID: "wine-staging"
        )

        bottle.engineID = "gptk"
        bottle.updatedAt = Date(timeIntervalSinceReferenceDate: 42)
        try await store.save(bottle)

        let bottles = try await store.bottles()
        XCTAssertEqual(bottles.count, 1)
        XCTAssertEqual(bottles.first?.engineID, "gptk")
        XCTAssertEqual(bottles.first?.provisionedEngineID, "wine-staging")
        XCTAssertEqual(bottles.first?.updatedAt, bottle.updatedAt)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "StillTests")
            .appending(path: UUID().uuidString)
    }
}
