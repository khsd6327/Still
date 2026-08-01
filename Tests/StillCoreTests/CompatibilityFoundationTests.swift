import Foundation
import XCTest
@testable import StillCore

final class CompatibilityFoundationTests: XCTestCase {
    func testRegistryFiltersImpossibleBackendAndSyncChoices() {
        let registry = makeRegistry(
            engineCapabilities: [.win64, .esync],
            componentCapabilities: [.dxmt]
        )

        XCTAssertEqual(registry.supportedGraphicsBackends(), [.wineD3D])
        XCTAssertEqual(registry.supportedSyncModes(), [.automatic, .none, .esync])
        XCTAssertFalse(registry.supports(.dxmtBridge))
        XCTAssertFalse(registry.supports(.msync))
    }

    func testLicenseStateParticipatesInCapabilities() {
        let engine = EngineBuild(
            id: "gptk-1",
            family: .gamePortingToolkit,
            displayName: "GPTK",
            version: "1",
            installURL: URL(filePath: "/tmp/gptk"),
            capabilities: [.win64, .d3dMetal],
            requiredLicenseID: "apple-gptk"
        )
        let host = HostCapabilitySnapshot(
            architecture: .arm64,
            supportsMetal: true,
            supportsRosetta: true
        )
        XCTAssertFalse(CapabilityRegistry(host: host, engine: engine, components: []).supports(.d3dMetal))

        let acceptedHost = HostCapabilitySnapshot(
            architecture: .arm64,
            supportsMetal: true,
            supportsRosetta: true,
            acceptedLicenseIDs: ["apple-gptk"]
        )
        XCTAssertTrue(CapabilityRegistry(host: acceptedHost, engine: engine, components: []).supports(.d3dMetal))
    }

    func testResolverTracksEverySourceAndOneShotOverrideExpires() throws {
        let environment = WindowsEnvironment(
            name: "Game",
            prefixURL: URL(filePath: "/tmp/Game"),
            graphicsBackend: .wineD3D,
            windowsVersion: .windows10,
            enhancedSync: .automatic
        )
        let profile = CompatibilityProfile(
            id: "tested-game",
            displayName: "Tested Game",
            matchRules: [],
            recommendedSettings: CompatibilitySettings(
                enhancedSync: .esync,
                environmentVariables: ["PROFILE": "1"],
                launchArguments: ["--profile"]
            )
        )
        let application = CompatibilitySettings(
            windowsVersion: .windows11,
            environmentVariables: ["APP": "1"]
        )
        let oneShot = CompatibilitySettings(
            graphicsBackend: .dxmt,
            environmentVariables: ["TEMP": "1"],
            launchArguments: ["--diagnostic"]
        )
        let registry = makeRegistry(
            engineCapabilities: [.win64, .esync],
            componentCapabilities: [.dxmt, .dxmtBridge]
        )
        let resolver = CompatibilityResolver()
        let effective = try resolver.resolve(
            environment: environment,
            profile: profile,
            applicationOverrides: application,
            launchOverrides: oneShot,
            registry: registry
        )

        XCTAssertEqual(effective.windowsVersion.source, .applicationOverride)
        XCTAssertEqual(effective.graphicsBackend.source, .launchOverride)
        XCTAssertEqual(effective.enhancedSync.source, .profile("tested-game"))
        XCTAssertEqual(effective.environmentVariables["PROFILE"]?.source, .profile("tested-game"))
        XCTAssertEqual(effective.environmentVariables["APP"]?.source, .applicationOverride)
        XCTAssertEqual(effective.environmentVariables["TEMP"]?.source, .launchOverride)
        XCTAssertEqual(effective.launchArgumentSource, .launchOverride)

        let nextLaunch = try resolver.resolve(
            environment: environment,
            profile: profile,
            applicationOverrides: application,
            registry: registry
        )
        XCTAssertEqual(nextLaunch.graphicsBackend.value, .wineD3D)
        XCTAssertEqual(nextLaunch.graphicsBackend.source, .environment)
        XCTAssertNil(nextLaunch.environmentVariables["TEMP"])
        XCTAssertEqual(nextLaunch.launchArguments, ["--profile"])
    }

    func testTypedDependencyPlanContainsNoExecutableScript() throws {
        let profile = CompatibilityProfile(
            id: "typed",
            displayName: "Typed",
            matchRules: [],
            dependencies: [ComponentDependency(componentID: "dxmt", exactVersion: "0.72")]
        )
        XCTAssertEqual(
            DependencyPlanner().plan(profile: profile, installedComponents: []),
            [.installComponent(id: "dxmt", exactVersion: "0.72")]
        )
        let encoded = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        XCTAssertFalse(encoded.contains("shell"))
        XCTAssertFalse(encoded.contains("script"))
    }

    func testProfileEngineFamilyIsEnforced() {
        let environment = WindowsEnvironment(
            name: "Test",
            prefixURL: URL(filePath: "/tmp/Test")
        )
        let profile = CompatibilityProfile(
            id: "staging-only",
            displayName: "Staging Only",
            matchRules: [],
            requiredEngineFamily: .wineStaging
        )

        XCTAssertThrowsError(try CompatibilityResolver().resolve(
            environment: environment,
            profile: profile,
            engineFamily: .gamePortingToolkit,
            registry: makeRegistry(
                engineCapabilities: [.win64],
                componentCapabilities: []
            )
        ))
    }

    func testSteamProfileMatchesClientButNotSteamGames() {
        let matcher = CompatibilityProfileMatcher()
        let environmentID = UUID()
        let client = LibraryApplication(
            environmentID: environmentID,
            name: "Steam",
            providerID: "steam",
            selectedProfileID: BundledCompatibilityProfiles.steam.id
        )
        let game = LibraryApplication(
            environmentID: environmentID,
            name: "Game",
            providerID: "steam",
            providerItemID: "123",
            selectedProfileID: BundledCompatibilityProfiles.steam.id
        )

        XCTAssertEqual(
            matcher.profile(
                for: client,
                executableURL: URL(filePath: "/tmp/steam.exe"),
                profiles: BundledCompatibilityProfiles.all
            )?.id,
            BundledCompatibilityProfiles.steam.id
        )
        XCTAssertNil(matcher.profile(
            for: game,
            executableURL: URL(filePath: "/tmp/steam.exe-placeholder/game.exe"),
            profiles: BundledCompatibilityProfiles.all
        ))
    }

    func testEnginePinChangeRequiresStopApprovalAndRestorePoint() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "StillEnginePinTests")
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let environment = WindowsEnvironment(
            name: "Game",
            prefixURL: rootURL.appending(path: "Prefix"),
            pinnedEngineBuildID: "old"
        )
        let old = EngineBuild(
            id: "old", family: .wineStaging, displayName: "Old", version: "1",
            installURL: rootURL.appending(path: "old"), capabilities: [.win64]
        )
        let new = EngineBuild(
            id: "new", family: .wineStaging, displayName: "New", version: "2",
            installURL: rootURL.appending(path: "new"), capabilities: [.win64]
        )
        let store = JSONStillStore(rootURL: rootURL)
        try await store.save(StillStoreDocument(
            environments: [environment],
            engineBuilds: [old, new]
        ))
        var active = LaunchSession(environmentID: environment.id)
        try active.transition(to: .launching)
        try active.transition(to: .running, rootProcessIdentifier: 1)

        do {
            try await store.updatePinnedEngine(
                environmentID: environment.id,
                engineBuildID: new.id,
                activeSessions: [active],
                userApproved: true,
                restorePointCreated: true
            )
            XCTFail("Expected active-session guard")
        } catch let error as StillCoreError {
            guard case .engineChangeRequirementsNotMet = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try await store.updatePinnedEngine(
            environmentID: environment.id,
            engineBuildID: new.id,
            activeSessions: [],
            userApproved: true,
            restorePointCreated: true
        )
        let reloadedEngineID = try await store.environment(id: environment.id)?.pinnedEngineBuildID
        XCTAssertEqual(reloadedEngineID, "new")
    }

    private func makeRegistry(
        engineCapabilities: EngineCapabilities,
        componentCapabilities: Set<RuntimeCapability>
    ) -> CapabilityRegistry {
        CapabilityRegistry(
            host: HostCapabilitySnapshot(
                architecture: .arm64,
                supportsMetal: true,
                supportsRosetta: true
            ),
            engine: EngineBuild(
                id: "test",
                family: .wineStaging,
                displayName: "Test",
                version: "1",
                installURL: URL(filePath: "/tmp/test"),
                capabilities: engineCapabilities
            ),
            components: [
                RuntimeComponent(
                    id: "components",
                    displayName: "Components",
                    version: "1",
                    installURL: URL(filePath: "/tmp/components"),
                    capabilities: componentCapabilities
                )
            ]
        )
    }
}
