import Foundation
import XCTest
@testable import StillCore

final class BottleProvisionerTests: XCTestCase {
    func testCreatesPreparedBottleWithSelectedEngine() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "StillBottleProvisionerTests")
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = JSONBottleStore(rootURL: rootURL)
        let engine = PreparingTestEngine()
        let provisioner = BottleProvisioner(bottleStore: store)

        let bottle = try await provisioner.create(
            name: "Prepared",
            engine: engine
        )

        XCTAssertEqual(bottle.engineID, engine.descriptor.id)
        XCTAssertEqual(bottle.provisionedEngineID, engine.descriptor.id)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bottle.prefixURL.path)
        )
        let storedBottles = try await store.bottles()
        XCTAssertEqual(storedBottles, [bottle])
    }
}

private struct PreparingTestEngine: WineEngine {
    let descriptor = EngineDescriptor(
        id: "preparing-test",
        displayName: "Preparing Test",
        version: "1",
        wineBinaryURL: URL(filePath: "/usr/bin/true"),
        capabilities: [.win64]
    )

    func prepare(_ bottle: Bottle) async throws {
        try FileManager.default.createDirectory(
            at: bottle.prefixURL,
            withIntermediateDirectories: true
        )
    }

    func launch(_ request: LaunchRequest) async throws -> LaunchSession {
        throw StillCoreError.engineNotFound(descriptor.id)
    }

    func stop(sessionID: LaunchSession.ID) async throws {
        throw StillCoreError.sessionNotFound(sessionID)
    }
}
