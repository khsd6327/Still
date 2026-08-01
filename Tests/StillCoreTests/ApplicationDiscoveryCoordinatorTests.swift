import Foundation
import XCTest
@testable import StillCore

final class ApplicationDiscoveryCoordinatorTests: XCTestCase {
    func testCoordinatorKeepsHigherConfidenceDuplicate() throws {
        let root = URL(filePath: "/tmp/still-discovery")
        let low = candidate(name: "Low", path: root.appending(path: "app.exe"), confidence: .medium)
        let high = candidate(name: "High", path: root.appending(path: "app.exe"), confidence: .high)
        let coordinator = ApplicationDiscoveryCoordinator(providers: [
            StubDiscoveryProvider(id: "low", candidates: [low]),
            StubDiscoveryProvider(id: "high", candidates: [high])
        ])

        let result = coordinator.discover(in: Bottle(name: "Test", prefixURL: root))

        XCTAssertEqual(result.accepted.map(\.application.name), ["High"])
        XCTAssertTrue(result.requiresConfirmation.isEmpty)
    }

    func testGenericExecutableRequiresConfirmation() throws {
        let prefix = FileManager.default.temporaryDirectory
            .appending(path: "StillDiscovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }
        let executable = prefix.appending(path: "drive_c/Program Files/Acme/Acme.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("MZ".utf8).write(to: executable)

        let result = ApplicationDiscoveryCoordinator(
            providers: [ExecutableDiscoveryProvider()]
        ).discover(in: Bottle(name: "Test", prefixURL: prefix))

        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.requiresConfirmation.count, 1)
        XCTAssertEqual(result.requiresConfirmation.first?.confidence, .medium)
    }

    func testSteamProviderClassifiesClientAndGame() throws {
        let prefix = FileManager.default.temporaryDirectory
            .appending(path: "StillSteamDiscovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }
        let steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
        let steamapps = steam.appending(path: "steamapps")
        let game = steamapps.appending(path: "common/Test Game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: steam.appending(path: "steam.exe"))
        try #"""
        "AppState"
        {
            "appid" "42"
            "name" "Test Game"
            "StateFlags" "4"
            "installdir" "Test Game"
        }
        """#.write(
            to: steamapps.appending(path: "appmanifest_42.acf"),
            atomically: true,
            encoding: .utf8
        )

        let result = ApplicationDiscoveryCoordinator(
            providers: [SteamDiscoveryProvider()]
        ).discover(in: Bottle(name: "Steam", prefixURL: prefix))

        XCTAssertEqual(result.accepted.count, 2)
        XCTAssertEqual(result.accepted.first(where: { $0.application.name == "Steam" })?.category, .launcher)
        XCTAssertEqual(result.accepted.first(where: { $0.application.name == "Test Game" })?.category, .game)
        XCTAssertEqual(result.accepted.first(where: { $0.application.name == "Test Game" })?.providerManagedState, .installed)
    }

    private func candidate(
        name: String,
        path: URL,
        confidence: DiscoveryConfidence
    ) -> DiscoveredApplicationCandidate {
        DiscoveredApplicationCandidate(
            providerID: "shared",
            application: InstalledWindowsApplication(
                id: path.path,
                name: name,
                source: .standalone,
                sourceIdentifier: nil,
                installState: .installed,
                installDirectoryURL: path.deletingLastPathComponent(),
                launcherURL: path
            ),
            category: .application,
            confidence: confidence,
            requiresConfirmation: false
        )
    }
}

private struct StubDiscoveryProvider: ApplicationDiscoveryProvider {
    let id: String
    let candidates: [DiscoveredApplicationCandidate]

    func discover(in bottle: Bottle) throws -> [DiscoveredApplicationCandidate] {
        candidates
    }
}
