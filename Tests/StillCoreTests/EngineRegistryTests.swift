import Foundation
import XCTest
@testable import StillCore

final class EngineRegistryTests: XCTestCase {
    func testRegistersAndResolvesEngine() async throws {
        let registry = EngineRegistry()
        let engine = StubEngine(id: "wine-test")

        try await registry.register(engine)
        let resolved = try await registry.engine(id: "wine-test")

        XCTAssertEqual(resolved.descriptor, engine.descriptor)
    }

    func testRejectsDuplicateEngineIDs() async throws {
        let registry = EngineRegistry()
        let engine = StubEngine(id: "wine-test")
        try await registry.register(engine)

        do {
            try await registry.register(engine)
            XCTFail("Expected a duplicate engine ID error.")
        } catch let error as StillCoreError {
            XCTAssertEqual(error, .duplicateEngineID("wine-test"))
        }
    }
}

private struct StubEngine: WineEngine {
    let descriptor: EngineDescriptor

    init(id: String) {
        descriptor = EngineDescriptor(
            id: id,
            displayName: "Test Wine",
            version: "0",
            wineBinaryURL: URL(filePath: "/usr/bin/false"),
            capabilities: [.win64]
        )
    }

    func prepare(_ bottle: Bottle) async throws {}

    func launch(_ request: LaunchRequest) async throws -> LaunchSession {
        LaunchSession(processIdentifier: 0)
    }

    func stop(sessionID: LaunchSession.ID) async throws {}
}

