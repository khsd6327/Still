import Foundation
import StillCore

@main
struct StillChecks {
    static func main() async {
        do {
            try await checkBottleStore()
            try await checkInvalidBottleName()
            try await checkEngineRegistry()
            print("All Still core checks passed.")
        } catch {
            FileHandle.standardError.write(Data("check failed: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func checkBottleStore() async throws {
        let rootURL = temporaryRoot()
        let store = JSONBottleStore(rootURL: rootURL)
        let created = try await store.create(
            name: "Steam",
            engineID: "winehq-11.10",
            graphicsBackend: .dxmt,
            windowsVersion: .windows11
        )
        let reloaded = try await JSONBottleStore(rootURL: rootURL).bottles()

        try require(reloaded == [created], "Bottle did not survive a store reload.")
        try require(
            reloaded[0].prefixURL.lastPathComponent == created.id.uuidString,
            "Bottle prefix is not derived from its stable ID."
        )
    }

    private static func checkInvalidBottleName() async throws {
        let store = JSONBottleStore(rootURL: temporaryRoot())
        do {
            _ = try await store.create(name: "   ")
            throw CheckError.failed("An empty bottle name was accepted.")
        } catch StillCoreError.invalidBottleName {
            return
        }
    }

    private static func checkEngineRegistry() async throws {
        let registry = EngineRegistry()
        let engine = StubEngine(id: "wine-test")
        try await registry.register(engine)
        let resolved = try await registry.engine(id: engine.descriptor.id)
        try require(resolved.descriptor == engine.descriptor, "Engine lookup returned the wrong engine.")

        do {
            try await registry.register(engine)
            throw CheckError.failed("A duplicate engine ID was accepted.")
        } catch StillCoreError.duplicateEngineID("wine-test") {
            return
        }
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "StillChecks")
            .appending(path: UUID().uuidString)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw CheckError.failed(message)
        }
    }
}

private enum CheckError: Error {
    case failed(String)
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
