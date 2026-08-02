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

    func testBuiltInDXMTStillRequiresValidatedBridge() {
        let engine = EngineBuild(
            id: "still-dxmt",
            family: .wineStaging,
            displayName: "Still DXMT",
            version: "11.14",
            installURL: URL(filePath: "/tmp/still-dxmt"),
            capabilities: [.win64, .dxmt]
        )
        let host = HostCapabilitySnapshot(
            architecture: .arm64,
            supportsMetal: true,
            supportsRosetta: true
        )

        let invalid = CapabilityRegistry(
            host: host,
            engine: engine,
            components: [],
            bridgeAvailability: .unavailable("Bridge integrity failed.")
        )
        XCTAssertTrue(invalid.supports(.dxmt))
        XCTAssertFalse(invalid.supports(.dxmtBridge))
        XCTAssertFalse(invalid.supportedGraphicsBackends().contains(.dxmt))

        let valid = CapabilityRegistry(
            host: host,
            engine: engine,
            components: [],
            bridgeAvailability: .available()
        )
        XCTAssertTrue(valid.supportedGraphicsBackends().contains(.dxmt))
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

    func testResolverTracksRuntimePolicyAndLetsExplicitOverridesWin() throws {
        let environment = WindowsEnvironment(
            name: "Steam",
            prefixURL: URL(filePath: "/tmp/Steam"),
            graphicsBackend: .dxmt
        )
        let effective = try CompatibilityResolver().resolve(
            environment: environment,
            runtimePolicySettings: CompatibilitySettings(
                environmentVariables: ["REMOTE_MODE": "stable"]
            ),
            runtimePolicyID: "steam-client",
            applicationOverrides: CompatibilitySettings(
                environmentVariables: ["REMOTE_MODE": "diagnostic"]
            ),
            registry: makeRegistry(
                engineCapabilities: [.win64],
                componentCapabilities: [.dxmt, .dxmtBridge]
            )
        )

        XCTAssertEqual(effective.environmentVariables["REMOTE_MODE"]?.value, "diagnostic")
        XCTAssertEqual(
            effective.environmentVariables["REMOTE_MODE"]?.source,
            .applicationOverride
        )
    }

    func testLaunchArgumentMergerReplacesPairedAndEqualsOptionsWithoutOrphans() {
        XCTAssertEqual(
            LaunchArgumentMerger.merge(
                ["-applaunch", "2488370", "-screen-width", "1280", "-ResX=1280"],
                ["-screen-width", "1920", "-ResX=1920"]
            ),
            ["-applaunch", "2488370", "-screen-width", "1920", "-ResX=1920"]
        )
        XCTAssertEqual(
            LaunchArgumentMerger.merge(["-flag"], ["-flag"]),
            ["-flag"]
        )
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
            providerItemID: "client",
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

    func testKnownSteamGamesMatchTheirOwnProfiles() {
        let matcher = CompatibilityProfileMatcher()
        let environmentID = UUID()
        let cashCleaner = LibraryApplication(
            environmentID: environmentID,
            name: "Cash Cleaner Simulator",
            providerID: "steam",
            providerItemID: "2488370"
        )
        let supermarketChaos = LibraryApplication(
            environmentID: environmentID,
            name: "Supermarket Chaos",
            providerID: "steam",
            providerItemID: "4800590"
        )

        XCTAssertEqual(
            matcher.profile(
                for: cashCleaner,
                executableURL: URL(filePath: "/tmp/steam.exe"),
                profiles: BundledCompatibilityProfiles.all
            )?.id,
            BundledCompatibilityProfiles.cashCleanerSimulator.id
        )
        XCTAssertEqual(
            matcher.profile(
                for: supermarketChaos,
                executableURL: URL(filePath: "/tmp/steam.exe"),
                profiles: BundledCompatibilityProfiles.all
            )?.id,
            BundledCompatibilityProfiles.supermarketChaos.id
        )
    }

    func testDiscoveryPreservesAnExistingProfileSelection() {
        let matcher = CompatibilityProfileMatcher()
        let application = LibraryApplication(
            environmentID: UUID(),
            name: "Steam",
            providerID: "steam",
            providerItemID: "client"
        )

        XCTAssertEqual(
            matcher.profileIDForDiscovery(
                existingSelection: "user-selected",
                application: application,
                executableURL: URL(filePath: "/tmp/steam.exe"),
                profiles: BundledCompatibilityProfiles.all
            ),
            "user-selected"
        )
        XCTAssertEqual(
            matcher.profileIDForDiscovery(
                existingSelection: nil,
                application: application,
                executableURL: URL(filePath: "/tmp/steam.exe"),
                profiles: BundledCompatibilityProfiles.all
            ),
            BundledCompatibilityProfiles.steam.id
        )
    }

    func testDiscoveryReplacesMismatchedBundledSteamProfileWithGameProfile() {
        let matcher = CompatibilityProfileMatcher()
        let application = LibraryApplication(
            environmentID: UUID(),
            name: "Cash Cleaner Simulator",
            providerID: "steam",
            providerItemID: "2488370"
        )

        XCTAssertEqual(
            matcher.profileIDForDiscovery(
                existingSelection: BundledCompatibilityProfiles.steam.id,
                application: application,
                executableURL: URL(filePath: "/tmp/steam.exe"),
                profiles: BundledCompatibilityProfiles.all
            ),
            BundledCompatibilityProfiles.cashCleanerSimulator.id
        )
    }

    func testCompatibilityProfileRequiresExactDXMTRevision() throws {
        let revision = "3525d41c71604ed07d796de5b58560e3cf6db944"
        let profile = CompatibilityProfile(
            id: "exact-dxmt",
            displayName: "Exact DXMT",
            matchRules: [],
            requiredEngineFamily: .wineStaging,
            requiredDXMTRevision: revision
        )
        let environment = WindowsEnvironment(
            name: "Game",
            prefixURL: URL(filePath: "/tmp/StillExactDXMT")
        )
        let registry = makeRegistry(
            engineCapabilities: [],
            componentCapabilities: []
        )

        XCTAssertThrowsError(try CompatibilityResolver().resolve(
            environment: environment,
            profile: profile,
            engineFamily: .wineStaging,
            engineDXMTRevision: "different",
            registry: registry
        ))
        XCTAssertNoThrow(try CompatibilityResolver().resolve(
            environment: environment,
            profile: profile,
            engineFamily: .wineStaging,
            engineDXMTRevision: revision,
            registry: registry
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

    func testInstalledEngineBuildSynchronizationUpsertsWithoutDroppingHistory() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "StillEngineSyncTests")
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let historical = EngineBuild(
            id: "historical", family: .wineStable, displayName: "Historical", version: "1",
            installURL: rootURL.appending(path: "historical"), capabilities: [.win64]
        )
        let stale = EngineBuild(
            id: "local", family: .wineStaging, displayName: "Local", version: "1",
            installURL: rootURL.appending(path: "old"), capabilities: [.win64]
        )
        let current = EngineBuild(
            id: "local", family: .wineStaging, displayName: "Local DXMT", version: "2",
            installURL: rootURL.appending(path: "current"), capabilities: [.win64, .dxmt]
        )
        let store = JSONStillStore(rootURL: rootURL)
        try await store.save(StillStoreDocument(engineBuilds: [historical, stale]))

        try await store.synchronizeInstalledEngineBuilds([current])

        let builds = try await store.load().engineBuilds
        XCTAssertEqual(builds.count, 2)
        XCTAssertEqual(builds.first(where: { $0.id == "local" }), current)
        XCTAssertTrue(builds.contains(historical))
    }

    func testInstalledEngineBuildSynchronizationRejectsArtifactIdentityChange() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "StillEngineIdentityTests")
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let recorded = EngineBuild(
            id: "local",
            family: .wineStaging,
            displayName: "Local",
            version: "1",
            installURL: rootURL.appending(path: "Engine"),
            capabilities: [.win64, .dxmt],
            artifactManifestSHA256: String(repeating: "a", count: 64)
        )
        let replaced = EngineBuild(
            id: "local",
            family: .wineStaging,
            displayName: "Local",
            version: "1",
            installURL: rootURL.appending(path: "Engine"),
            capabilities: [.win64, .dxmt],
            artifactManifestSHA256: String(repeating: "b", count: 64)
        )
        let store = JSONStillStore(rootURL: rootURL)
        try await store.save(StillStoreDocument(engineBuilds: [recorded]))

        do {
            try await store.synchronizeInstalledEngineBuilds([replaced])
            XCTFail("Expected immutable engine identity failure")
        } catch let error as StillCoreError {
            guard case .verificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.engineBuilds, [recorded])
    }

    func testInstalledEngineBuildSynchronizationUpgradesLegacyLocalManifestIdentity() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "StillEngineManifestUpgradeTests")
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let installURL = rootURL.appending(path: "Engine/bin")
        let legacy = EngineBuild(
            id: "local-dxmt",
            family: .wineStaging,
            displayName: "Local DXMT",
            version: "11.14",
            installURL: installURL,
            capabilities: [.win64, .dxmt],
            artifactManifestSHA256: String(repeating: "a", count: 64)
        )
        let upgraded = EngineBuild(
            id: legacy.id,
            family: legacy.family,
            displayName: legacy.displayName,
            version: legacy.version,
            wineVersion: "11.14",
            dxmtRevision: "3525d41c71604ed07d796de5b58560e3cf6db944",
            installURL: installURL,
            capabilities: legacy.capabilities,
            artifactManifestSHA256: String(repeating: "b", count: 64)
        )
        let store = JSONStillStore(rootURL: rootURL)
        try await store.save(StillStoreDocument(engineBuilds: [legacy]))

        try await store.synchronizeInstalledEngineBuilds([upgraded])

        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.engineBuilds, [upgraded])
    }

    func testManagedRuntimeReplacementRemapsEntriesAndRetainsSource() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "StillRuntimeReplacementTests")
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let environmentID = UUID()
        let sourceURL = rootURL.appending(path: "Source")
        let destinationURL = rootURL
            .appending(path: "Environments")
            .appending(path: environmentID.uuidString)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let application = LibraryApplication(environmentID: environmentID, name: "Steam")
        let entry = LaunchEntry(
            applicationID: application.id,
            executableURL: sourceURL.appending(path: "drive_c/Steam/steam.exe"),
            workingDirectoryURL: sourceURL.appending(path: "drive_c/Steam")
        )
        var storedApplication = application
        storedApplication.launchEntryIDs = [entry.id]
        let oldEnvironment = WindowsEnvironment(
            id: environmentID,
            name: "Steam",
            prefixURL: sourceURL,
            pinnedEngineBuildID: "old"
        )
        let engine = EngineBuild(
            id: "dxmt", family: .wineStaging, displayName: "DXMT", version: "1",
            installURL: rootURL.appending(path: "Engine"), capabilities: [.win64, .dxmt]
        )
        let store = JSONStillStore(rootURL: rootURL)
        try await store.save(StillStoreDocument(
            environments: [oldEnvironment],
            applications: [storedApplication],
            launchEntries: [entry],
            engineBuilds: [engine]
        ))
        let replacement = WindowsEnvironment(
            id: environmentID,
            name: "Steam",
            prefixURL: destinationURL,
            pinnedEngineBuildID: engine.id,
            provisionedEngineBuildID: engine.id,
            graphicsBackend: .dxmt,
            ownership: .managed,
            managementNonce: UUID(),
            createdAt: oldEnvironment.createdAt
        )

        try await store.commitManagedRuntimeReplacement(
            environment: replacement,
            expectedSourcePrefixURL: sourceURL,
            activeSessions: [],
            userApproved: true,
            sourcePrefixRetained: true
        )

        let document = try await store.load()
        XCTAssertEqual(
            document.environments.first?.prefixURL.standardizedFileURL.path,
            destinationURL.standardizedFileURL.path
        )
        XCTAssertEqual(document.environments.first?.pinnedEngineBuildID, engine.id)
        XCTAssertEqual(
            document.launchEntries.first?.executableURL.standardizedFileURL.path,
            destinationURL.appending(path: "drive_c/Steam/steam.exe").standardizedFileURL.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
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
