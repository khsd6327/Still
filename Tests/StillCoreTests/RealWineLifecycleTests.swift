import Foundation
import XCTest
@testable import StillCore

final class RealWineLifecycleTests: XCTestCase {
    func testRelaunchRecoveryAndCrossEnvironmentIsolationWithRealWine() async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment["STILL_REAL_WINE_BINARY"],
              FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw XCTSkip("Set STILL_REAL_WINE_BINARY to run the real-Wine lifecycle fixture.")
        }

        let wineURL = URL(filePath: binaryPath)
        let wineserverURL = wineURL.deletingLastPathComponent().appending(path: "wineserver")
        let root = FileManager.default.temporaryDirectory
            .appending(path: "StillRealWineLifecycleTests")
            .appending(path: UUID().uuidString)
        let prefixA = root.appending(path: "Environment A")
        let prefixB = root.appending(path: "Environment B")
        try FileManager.default.createDirectory(at: prefixA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefixB, withIntermediateDirectories: true)
        defer {
            stopWineServer(wineserverURL, prefix: prefixA)
            stopWineServer(wineserverURL, prefix: prefixB)
            try? FileManager.default.removeItem(at: root)
        }

        try initializePrefix(wineURL, prefix: prefixA)
        try initializePrefix(wineURL, prefix: prefixB)

        let environmentA = WindowsEnvironment(name: "A", prefixURL: prefixA)
        let environmentB = WindowsEnvironment(name: "B", prefixURL: prefixB)
        let entryA = LaunchEntry(
            applicationID: UUID(),
            executableURL: prefixA.appending(path: "drive_c/windows/system32/cmd.exe")
        )
        let entryB = LaunchEntry(
            applicationID: UUID(),
            executableURL: prefixB.appending(path: "drive_c/windows/system32/cmd.exe")
        )
        let applicationA = LibraryApplication(
            id: entryA.applicationID,
            environmentID: environmentA.id,
            name: "Command A",
            launchEntryIDs: [entryA.id]
        )
        let applicationB = LibraryApplication(
            id: entryB.applicationID,
            environmentID: environmentB.id,
            name: "Command B",
            launchEntryIDs: [entryB.id]
        )

        let processA = try startLongCommand(wineURL, prefix: prefixA)
        let processB = try startLongCommand(wineURL, prefix: prefixB)
        defer {
            if processA.isRunning { processA.terminate() }
            if processB.isRunning { processB.terminate() }
        }

        let firstSnapshot = try await waitForSnapshot(
            environments: [environmentA, environmentB],
            applications: [applicationA, applicationB],
            entries: [entryA, entryB]
        )
        XCTAssertEqual(firstSnapshot.liveEnvironmentIDs, [environmentA.id, environmentB.id])
        guard let firstObservationA = firstSnapshot.observations.first(where: {
            $0.applicationID == applicationA.id
        }) else {
            return XCTFail("Environment A did not expose cmd.exe.")
        }

        let engine = EngineDescriptor(
            id: "real-wine-fixture",
            displayName: "Real Wine Fixture",
            version: "1",
            family: .wineStable,
            wineBinaryURL: wineURL,
            capabilities: [.win64, .wow64, .esync]
        )
        let firstSupervisor = ProcessSupervisor()
        let firstPlan = WineCommandBuilder.launchPlan(
            engine: engine,
            request: LaunchRequest(
                bottle: Bottle(name: "A", prefixURL: prefixA, engineID: engine.id),
                executableURL: entryA.executableURL,
                applicationID: applicationA.id,
                environmentID: environmentA.id
            ),
            logURL: root.appending(path: "first-adoption.log")
        )
        let firstSession = try await firstSupervisor.adopt(
            firstPlan,
            observedProcessIdentifier: firstObservationA.processIdentifier,
            observedProcessName: firstObservationA.processName,
            observedProcessStartedAt: firstObservationA.processIdentity.startedAt
        )
        XCTAssertEqual(firstSession.state, .running)

        let relaunchedSupervisor = ProcessSupervisor()
        let relaunchedPlan = WineCommandBuilder.launchPlan(
            engine: engine,
            request: LaunchRequest(
                bottle: Bottle(name: "A", prefixURL: prefixA, engineID: engine.id),
                executableURL: entryA.executableURL,
                applicationID: applicationA.id,
                environmentID: environmentA.id
            ),
            logURL: root.appending(path: "relaunch-adoption.log")
        )
        let recoveredSession = try await relaunchedSupervisor.adopt(
            relaunchedPlan,
            observedProcessIdentifier: firstObservationA.processIdentifier,
            observedProcessName: firstObservationA.processName,
            observedProcessStartedAt: firstObservationA.processIdentity.startedAt
        )
        XCTAssertEqual(recoveredSession.state, .running)
        XCTAssertEqual(recoveredSession.rootProcessStartedAt, firstObservationA.processIdentity.startedAt)

        try await relaunchedSupervisor.forceStop(sessionID: recoveredSession.id)
        let isolatedSnapshot = try await waitForLiveEnvironments(
            expected: [environmentB.id],
            environments: [environmentA, environmentB]
        )
        XCTAssertEqual(isolatedSnapshot, [environmentB.id])

        for _ in 0..<50 {
            if await firstSupervisor.activeSessions().isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let firstSupervisorIsEmpty = await firstSupervisor.activeSessions().isEmpty
        XCTAssertTrue(firstSupervisorIsEmpty)

        let relaunchedProcessA = try startLongCommand(wineURL, prefix: prefixA)
        defer {
            if relaunchedProcessA.isRunning { relaunchedProcessA.terminate() }
        }
        let secondSnapshot = try await waitForSnapshot(
            environments: [environmentA, environmentB],
            applications: [applicationA, applicationB],
            entries: [entryA, entryB]
        )
        guard let secondObservationA = secondSnapshot.observations.first(where: {
            $0.applicationID == applicationA.id
        }) else {
            return XCTFail("Relaunched Environment A did not expose cmd.exe.")
        }
        XCTAssertFalse(firstObservationA.processIdentity.matches(
            HostProcessSnapshot(
                processIdentifier: secondObservationA.processIdentifier,
                residentMemoryKilobytes: 0,
                cpuPercent: 0,
                elapsedSeconds: 0,
                command: "cmd.exe",
                startedAt: secondObservationA.processIdentity.startedAt
            )
        ))
    }

    private func initializePrefix(_ wineURL: URL, prefix: URL) throws {
        let process = makeWineProcess(
            wineURL,
            prefix: prefix,
            arguments: ["cmd.exe", "/c", "exit", "/b", "0"]
        )
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func startLongCommand(_ wineURL: URL, prefix: URL) throws -> Process {
        let process = makeWineProcess(
            wineURL,
            prefix: prefix,
            arguments: ["cmd.exe", "/c", "ping -n 30 127.0.0.1 > NUL"]
        )
        try process.run()
        return process
    }

    private func makeWineProcess(
        _ wineURL: URL,
        prefix: URL,
        arguments: [String]
    ) -> Process {
        let process = Process()
        process.executableURL = wineURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = prefix.path
        environment["WINEDEBUG"] = "-all"
        environment["MVK_CONFIG_LOG_LEVEL"] = "0"
        process.environment = environment
        process.currentDirectoryURL = prefix
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func stopWineServer(_ wineserverURL: URL, prefix: URL) {
        guard FileManager.default.isExecutableFile(atPath: wineserverURL.path) else { return }
        let process = Process()
        process.executableURL = wineserverURL
        process.arguments = ["-k", "-w"]
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = prefix.path
        environment["WINEDEBUG"] = "-all"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func waitForSnapshot(
        environments: [WindowsEnvironment],
        applications: [LibraryApplication],
        entries: [LaunchEntry]
    ) async throws -> (
        liveEnvironmentIDs: Set<WindowsEnvironment.ID>,
        observations: [LiveWineApplicationObservation]
    ) {
        let deadline = Date().addingTimeInterval(12)
        var lastLive: Set<WindowsEnvironment.ID> = []
        var lastObservations: [LiveWineApplicationObservation] = []
        while Date() < deadline {
            let processes = try WineRuntimeProbe.runningProcesses()
            let live = WineRuntimeProbe.liveEnvironmentIDs(
                in: processes,
                environments: environments
            )
            let observations = applications.compactMap { application -> LiveWineApplicationObservation? in
                guard let environment = environments.first(where: {
                    $0.id == application.environmentID
                }),
                let entryID = application.launchEntryIDs.first,
                let entry = entries.first(where: { $0.id == entryID }) else {
                    return nil
                }
                let attributed = processes.filter {
                    WineRuntimeProbe.attributedEnvironmentID(
                        for: $0,
                        environments: environments
                    ) == environment.id
                }
                guard let process = attributed.first(where: {
                    !$0.command.localizedCaseInsensitiveContains("wineserver")
                }) ?? attributed.first else { return nil }
                return LiveWineApplicationObservation(
                    applicationID: application.id,
                    environmentID: environment.id,
                    processIdentifier: process.processIdentifier,
                    processName: entry.executableURL.lastPathComponent,
                    processIdentity: process.identity
                )
            }
            lastLive = live
            lastObservations = observations
            if live.count == environments.count,
               observations.count == applications.count {
                return (live, observations)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw StillCoreError.verificationFailed(
            "Real Wine processes were not observed in time. Live Environments: \(lastLive.count); applications: \(lastObservations.count)."
        )
    }

    private func waitForLiveEnvironments(
        expected: Set<WindowsEnvironment.ID>,
        environments: [WindowsEnvironment]
    ) async throws -> Set<WindowsEnvironment.ID> {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            let processes = try WineRuntimeProbe.runningProcesses(enrichWorkingDirectories: false)
            let live = WineRuntimeProbe.liveEnvironmentIDs(
                in: processes,
                environments: environments
            )
            if live == expected { return live }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw StillCoreError.verificationFailed("Wine Environment isolation was not observed in time.")
    }
}
