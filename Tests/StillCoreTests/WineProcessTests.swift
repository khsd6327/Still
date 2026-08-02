import Foundation
import XCTest
@testable import StillCore

final class WineProcessTests: XCTestCase {
    func testLaunchPlanUsesArgumentArrayAndBottleEnvironment() {
        let sessionID = UUID()
        let bottle = Bottle(
            name: "Steam",
            prefixURL: URL(filePath: "/tmp/Still Bottle"),
            engineID: "wine-test"
        )
        let engine = EngineDescriptor(
            id: "wine-test",
            displayName: "Test Wine",
            version: "1",
            wineBinaryURL: URL(filePath: "/opt/wine/bin/wine64"),
            capabilities: [.win64]
        )
        let request = LaunchRequest(
            bottle: bottle,
            executableURL: URL(filePath: "/tmp/My Game/game.exe"),
            arguments: ["--safe mode"],
            environment: ["STILL_TEST": "1"]
        )

        let plan = WineCommandBuilder.launchPlan(
            sessionID: sessionID,
            engine: engine,
            request: request,
            logURL: URL(filePath: "/tmp/still.log")
        )

        XCTAssertEqual(plan.executableURL, engine.wineBinaryURL)
        XCTAssertEqual(plan.sessionID, sessionID)
        XCTAssertEqual(
            plan.arguments,
            ["start", "/unix", "/tmp/My Game/game.exe", "--safe mode"]
        )
        XCTAssertEqual(plan.environment["WINEPREFIX"], "/tmp/Still Bottle")
        XCTAssertEqual(plan.environment["STILL_TEST"], "1")
        XCTAssertNil(plan.environment["SSH_AUTH_SOCK"])
        XCTAssertNil(plan.environment["NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S"])
        XCTAssertEqual(plan.terminationPlan?.scopeIdentifier, "/tmp/Still Bottle")
        XCTAssertNil(plan.terminationPlan?.hostProcessPathPrefix)
        XCTAssertEqual(plan.terminationPlan?.gracefulArguments, ["wineboot", "--end-session"])
        XCTAssertEqual(plan.terminationPlan?.forceArguments, ["-k", "-w"])
        XCTAssertEqual(
            plan.terminationPlan?.monitorExecutableURL,
            URL(filePath: "/opt/wine/bin/wineserver")
        )
        XCTAssertEqual(plan.terminationPlan?.monitorArguments, ["-w"])
    }

    func testLaunchPlanScopesHostTerminationToWindowsWorkingDirectory() {
        let bottle = Bottle(
            name: "Steam",
            prefixURL: URL(filePath: "/tmp/Still Bottle"),
            engineID: "wine-test"
        )
        let engine = EngineDescriptor(
            id: "wine-test",
            displayName: "Test Wine",
            version: "1",
            wineBinaryURL: URL(filePath: "/opt/wine/bin/wine64"),
            capabilities: [.win64]
        )
        let gameDirectory = bottle.prefixURL.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps/common/ChaosMarket"
        )

        let plan = WineCommandBuilder.launchPlan(
            engine: engine,
            request: LaunchRequest(
                bottle: bottle,
                executableURL: gameDirectory.appending(path: "Supermarket Chaos.exe"),
                workingDirectoryURL: gameDirectory
            ),
            logURL: URL(filePath: "/tmp/still.log")
        )

        XCTAssertEqual(
            plan.terminationPlan?.hostProcessPathPrefix,
            "C:\\Program Files (x86)\\Steam\\steamapps\\common\\ChaosMarket\\"
        )
    }

    func testHostProcessListParserPreservesCommandLine() {
        let output = """
              42 C:\\Games\\Example\\game.exe --windowed
             105 /usr/bin/true
            invalid
            """

        XCTAssertEqual(
            HostProcessTerminator.parseProcessList(output),
            [
                HostProcessRecord(
                    processIdentifier: 42,
                    command: "C:\\Games\\Example\\game.exe --windowed"
                ),
                HostProcessRecord(processIdentifier: 105, command: "/usr/bin/true")
            ]
        )
    }

    func testNormalAndForceStopPlansAreDistinct() {
        let bottle = Bottle(
            name: "Steam",
            prefixURL: URL(filePath: "/tmp/Still Bottle"),
            engineID: "wine-test"
        )
        let engine = EngineDescriptor(
            id: "wine-test",
            displayName: "Test Wine",
            version: "1",
            wineBinaryURL: URL(filePath: "/opt/wine/bin/wine64"),
            capabilities: [.win64]
        )

        let plan = WineCommandBuilder.stopPlan(
            engine: engine,
            bottle: bottle,
            logURL: URL(filePath: "/tmp/stop.log")
        )

        XCTAssertEqual(plan.executableURL, engine.wineBinaryURL)
        XCTAssertEqual(plan.arguments, ["wineboot", "--end-session"])
        XCTAssertEqual(plan.environment["WINEPREFIX"], "/tmp/Still Bottle")

        let forcePlan = WineCommandBuilder.forceStopPlan(
            engine: engine,
            bottle: bottle,
            logURL: URL(filePath: "/tmp/force-stop.log")
        )
        XCTAssertEqual(forcePlan.executableURL, URL(filePath: "/opt/wine/bin/wineserver"))
        XCTAssertEqual(forcePlan.arguments, ["-k", "-w"])
    }

    func testCompatibilityEnvironmentUsesMSyncAndMetalDiagnostics() {
        let bottle = Bottle(
            name: "Game",
            prefixURL: URL(filePath: "/tmp/Game"),
            graphicsBackend: .d3dMetal,
            enhancedSync: .msync,
            metalHUDEnabled: true,
            metalTraceEnabled: true
        )
        let engine = EngineDescriptor(
            id: "gptk-test",
            displayName: "GPTK Test",
            version: "1",
            wineBinaryURL: URL(filePath: "/opt/gptk/bin/wine64"),
            capabilities: [.win64, .esync, .msync, .d3dMetal]
        )

        let plan = WineCommandBuilder.utilityPlan(
            engine: engine,
            bottle: bottle,
            arguments: ["winecfg"],
            logURL: URL(filePath: "/tmp/tool.log")
        )

        XCTAssertEqual(plan.environment["WINEMSYNC"], "1")
        XCTAssertEqual(plan.environment["WINEESYNC"], "1")
        XCTAssertEqual(plan.environment["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(plan.environment["METAL_CAPTURE_ENABLED"], "1")
    }

    func testDXMTEnvironmentDoesNotInjectDiagnosticShimByDefault() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "StillDXMTTests")
            .appending(path: UUID().uuidString)
        let wineURL = rootURL.appending(path: "wine/bin/wine")
        let bridgeURL = rootURL.appending(
            path: "wine/lib/wine/x86_64-unix/libstill-dxmt-macdrv-bridge.dylib"
        )
        try FileManager.default.createDirectory(
            at: bridgeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: bridgeURL.path,
            contents: Data()
        ))
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let bottle = Bottle(
            name: "DXMT Game",
            prefixURL: rootURL.appending(path: "prefix"),
            graphicsBackend: .dxmt
        )
        let engine = EngineDescriptor(
            id: "dxmt-test",
            displayName: "DXMT Test",
            version: "1",
            wineBinaryURL: wineURL,
            capabilities: [.win64, .esync]
        )

        let plan = WineCommandBuilder.utilityPlan(
            engine: engine,
            bottle: bottle,
            arguments: ["winecfg"],
            logURL: rootURL.appending(path: "dxmt.log")
        )

        XCTAssertEqual(
            plan.environment["WINEDLLOVERRIDES"],
            "dxgi,d3d9,d3d10core,d3d11=b"
        )
        XCTAssertNil(plan.environment["DYLD_INSERT_LIBRARIES"])
    }

#if DEBUG
    func testDXMTDiagnosticShimRequiresExplicitDebugOptIn() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "StillDXMTDiagnosticTests")
            .appending(path: UUID().uuidString)
        let wineURL = rootURL.appending(path: "wine/bin/wine")
        let bridgeURL = rootURL.appending(
            path: "wine/lib/wine/x86_64-unix/libstill-dxmt-macdrv-bridge.dylib"
        )
        try FileManager.default.createDirectory(
            at: bridgeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: bridgeURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let plan = WineCommandBuilder.utilityPlan(
            engine: EngineDescriptor(
                id: "dxmt-test", displayName: "DXMT Test", version: "1",
                wineBinaryURL: wineURL, capabilities: [.win64]
            ),
            bottle: Bottle(
                name: "DXMT", prefixURL: rootURL.appending(path: "prefix"),
                graphicsBackend: .dxmt
            ),
            arguments: ["winecfg"],
            logURL: rootURL.appending(path: "dxmt.log")
        )
        let optedIn = WineCommandBuilder.utilityPlan(
            engine: EngineDescriptor(
                id: "dxmt-test", displayName: "DXMT Test", version: "1",
                wineBinaryURL: wineURL, capabilities: [.win64]
            ),
            bottle: Bottle(
                name: "DXMT", prefixURL: rootURL.appending(path: "prefix"),
                graphicsBackend: .dxmt
            ),
            arguments: ["winecfg"],
            logURL: rootURL.appending(path: "dxmt-opt-in.log")
        )
        XCTAssertNil(plan.environment["DYLD_INSERT_LIBRARIES"])

        let direct = WineCommandBuilder.launchPlan(
            engine: EngineDescriptor(
                id: "dxmt-test", displayName: "DXMT Test", version: "1",
                wineBinaryURL: wineURL, capabilities: [.win64]
            ),
            request: LaunchRequest(
                bottle: Bottle(
                    name: "DXMT", prefixURL: rootURL.appending(path: "prefix"),
                    graphicsBackend: .dxmt
                ),
                executableURL: rootURL.appending(path: "game.exe"),
                environment: ["STILL_ENABLE_DXMT_DIAGNOSTIC_SHIM": "1"]
            ),
            logURL: rootURL.appending(path: "launch.log")
        )
        XCTAssertNil(optedIn.environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(direct.environment["DYLD_INSERT_LIBRARIES"], bridgeURL.path)
        XCTAssertNil(direct.environment["STILL_ENABLE_DXMT_DIAGNOSTIC_SHIM"])
    }
#endif

    func testDXMTEnvironmentDoesNotInjectMissingBridge() {
        let bottle = Bottle(
            name: "DXMT Game",
            prefixURL: URL(filePath: "/tmp/DXMT Game"),
            graphicsBackend: .dxmt
        )
        let engine = EngineDescriptor(
            id: "dxmt-test",
            displayName: "DXMT Test",
            version: "1",
            wineBinaryURL: URL(filePath: "/opt/dxmt/wine/bin/wine"),
            capabilities: [.win64]
        )

        let plan = WineCommandBuilder.utilityPlan(
            engine: engine,
            bottle: bottle,
            arguments: ["winecfg"],
            logURL: URL(filePath: "/tmp/dxmt.log")
        )

        XCTAssertNil(plan.environment["DYLD_INSERT_LIBRARIES"])
    }

    func testProcessSupervisorRunsExecutableAndWritesLog() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "StillProcessTests")
            .appending(path: UUID().uuidString)
        let logURL = rootURL.appending(path: "true.log")
        let plan = ProcessPlan(
            executableURL: URL(filePath: "/usr/bin/true"),
            arguments: [],
            logURL: logURL
        )

        let exitCode = try await ProcessSupervisor().runAndWait(plan)

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
    }

    func testProcessSupervisorPreservesSessionIdentity() async throws {
        let sessionID = UUID()
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "StillProcessTests")
            .appending(path: sessionID.uuidString)
        let logURL = rootURL.appending(path: "\(sessionID.uuidString).log")
        let plan = ProcessPlan(
            sessionID: sessionID,
            executableURL: URL(filePath: "/bin/sleep"),
            arguments: ["5"],
            logURL: logURL
        )
        let supervisor = ProcessSupervisor()

        let session = try await supervisor.launch(plan)
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.logURL, logURL)

        try await supervisor.stop(sessionID: sessionID)
    }
}
