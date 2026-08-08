import Foundation
import XCTest
@testable import StillCore

final class WineRuntimeProbeTests: XCTestCase {
    func testExactPrefixEnvironmentWinsOverWorkingDirectoryFallback() {
        let exactEnvironment = WindowsEnvironment(
            name: "Exact",
            prefixURL: URL(filePath: "/tmp/Exact")
        )
        let cwdEnvironment = WindowsEnvironment(
            name: "CWD",
            prefixURL: URL(filePath: "/tmp/CWD")
        )
        let process = HostProcessSnapshot(
            processIdentifier: 99,
            residentMemoryKilobytes: 1,
            cpuPercent: 0,
            elapsedSeconds: 1,
            command: "game.exe WINEPREFIX=/tmp/Exact",
            workingDirectoryPath: "/tmp/CWD/drive_c/Game"
        )

        XCTAssertEqual(
            WineRuntimeProbe.attributedEnvironmentID(
                for: process,
                environments: [cwdEnvironment, exactEnvironment]
            ),
            exactEnvironment.id
        )
    }

    func testWorkingDirectoryFallbackSelectsDeepestPrefix() {
        let parent = WindowsEnvironment(
            name: "Parent",
            prefixURL: URL(filePath: "/tmp/Prefixes")
        )
        let child = WindowsEnvironment(
            name: "Child",
            prefixURL: URL(filePath: "/tmp/Prefixes/Child")
        )
        let process = HostProcessSnapshot(
            processIdentifier: 100,
            residentMemoryKilobytes: 1,
            cpuPercent: 0,
            elapsedSeconds: 1,
            command: "C:\\Game\\game.exe",
            workingDirectoryPath: "/tmp/Prefixes/Child/drive_c/Game"
        )

        XCTAssertEqual(
            WineRuntimeProbe.attributedEnvironmentID(
                for: process,
                environments: [parent, child]
            ),
            child.id
        )
    }

    func testParsesHostMetricsAndElapsedTime() throws {
        let output = """
          120  77  4096  12.5  01:02 C:\\Games\\Sample\\game.exe --play
          121   1  2048   1.5 1-02:03:04 /opt/wine/bin/wineserver -p5 WINEPREFIX=/tmp/Test Prefix HOME=/tmp
        """

        let records = WineRuntimeProbe.parseProcessList(output)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].processIdentifier, 120)
        XCTAssertEqual(records[0].parentProcessIdentifier, 77)
        XCTAssertEqual(records[0].residentMemoryKilobytes, 4096)
        XCTAssertEqual(records[0].cpuPercent, 12.5)
        XCTAssertEqual(records[0].elapsedSeconds, 62)
        XCTAssertEqual(records[1].elapsedSeconds, 93_784)
        XCTAssertTrue(records[1].command.contains("WINEPREFIX=/tmp/Test Prefix"))
    }

    func testFindsOnlyDetachedStillPrefixMonitors() {
        let environment = WindowsEnvironment(
            name: "Steam",
            prefixURL: URL(filePath: "/tmp/Still Prefix")
        )
        let records = [
            HostProcessSnapshot(
                processIdentifier: 200,
                parentProcessIdentifier: 1,
                residentMemoryKilobytes: 512,
                cpuPercent: 0,
                elapsedSeconds: 10,
                command: "/opt/wine/bin/wineserver -w WINEPREFIX=/tmp/Still Prefix STILL_MONITOR_TOKEN=owned"
            ),
            HostProcessSnapshot(
                processIdentifier: 201,
                parentProcessIdentifier: 99,
                residentMemoryKilobytes: 512,
                cpuPercent: 0,
                elapsedSeconds: 10,
                command: "/opt/wine/bin/wineserver -w WINEPREFIX=/tmp/Still Prefix"
            ),
            HostProcessSnapshot(
                processIdentifier: 202,
                parentProcessIdentifier: 1,
                residentMemoryKilobytes: 512,
                cpuPercent: 0,
                elapsedSeconds: 10,
                command: "/opt/wine/bin/wineserver -w WINEPREFIX=/tmp/Other Prefix"
            )
        ]

        XCTAssertEqual(
            WineRuntimeProbe.orphanedMonitorProcessIdentifiers(
                in: records,
                environments: [environment]
            ),
            [200]
        )
    }

    func testObservesApplicationOnlyWhenItsEnvironmentHasLiveWineServer() {
        let environment = WindowsEnvironment(
            name: "Games",
            prefixURL: URL(filePath: "/tmp/Still Prefix")
        )
        let applicationID = UUID()
        let entry = LaunchEntry(
            applicationID: applicationID,
            executableURL: URL(filePath: "/tmp/Still Prefix/drive_c/Games/Sample/game.exe")
        )
        let application = LibraryApplication(
            id: applicationID,
            environmentID: environment.id,
            name: "Sample",
            category: .game,
            launchEntryIDs: [entry.id]
        )
        let records = [
            HostProcessSnapshot(
                processIdentifier: 400,
                residentMemoryKilobytes: 1_000,
                cpuPercent: 0,
                elapsedSeconds: 5,
                command: "/opt/wine/bin/wineserver -p5 WINEPREFIX=/tmp/Still Prefix HOME=/tmp"
            ),
            HostProcessSnapshot(
                processIdentifier: 420,
                residentMemoryKilobytes: 10_000,
                cpuPercent: 20,
                elapsedSeconds: 3,
                command: "C:\\Games\\Sample\\game.exe --play WINEPREFIX=/tmp/Still Prefix"
            )
        ]

        let observations = WineRuntimeProbe.observeApplications(
            in: records,
            environments: [environment],
            applications: [application],
            launchEntries: [entry]
        )

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].applicationID, application.id)
        XCTAssertEqual(observations[0].processIdentifier, 420)
    }

    func testSteamLauncherDoesNotMasqueradeAsEverySteamGame() {
        let environment = WindowsEnvironment(
            name: "Steam",
            prefixURL: URL(filePath: "/tmp/Prefix")
        )
        let launcherID = UUID()
        let gameID = UUID()
        let launcherEntry = LaunchEntry(
            applicationID: launcherID,
            executableURL: URL(filePath: "/tmp/Prefix/drive_c/Program Files/Steam/steam.exe"),
            workingDirectoryURL: URL(filePath: "/tmp/Prefix/drive_c/Program Files/Steam")
        )
        let gameEntry = LaunchEntry(
            applicationID: gameID,
            executableURL: launcherEntry.executableURL,
            arguments: ["-applaunch", "123"],
            workingDirectoryURL: URL(filePath: "/tmp/Prefix/drive_c/Program Files/Steam/steamapps/common/Game")
        )
        let launcher = LibraryApplication(
            id: launcherID,
            environmentID: environment.id,
            name: "Steam",
            launchEntryIDs: [launcherEntry.id]
        )
        let game = LibraryApplication(
            id: gameID,
            environmentID: environment.id,
            name: "Game",
            category: .game,
            launchEntryIDs: [gameEntry.id]
        )
        let records = [
            HostProcessSnapshot(
                processIdentifier: 1,
                residentMemoryKilobytes: 1,
                cpuPercent: 0,
                elapsedSeconds: 1,
                command: "/opt/wineserver -p5 WINEPREFIX=/tmp/Prefix HOME=/tmp"
            ),
            HostProcessSnapshot(
                processIdentifier: 2,
                residentMemoryKilobytes: 1,
                cpuPercent: 0,
                elapsedSeconds: 1,
                command: "C:\\Program Files\\Steam\\steam.exe WINEPREFIX=/tmp/Prefix"
            )
        ]

        let observations = WineRuntimeProbe.observeApplications(
            in: records,
            environments: [environment],
            applications: [launcher, game],
            launchEntries: [launcherEntry, gameEntry]
        )

        XCTAssertEqual(observations.map(\.applicationID), [launcherID])
    }

    func testPerformanceSnapshotAggregatesApplicationDirectoryProcesses() {
        let environment = WindowsEnvironment(
            name: "Steam",
            prefixURL: URL(filePath: "/tmp/Prefix"),
            pinnedEngineBuildID: "engine",
            graphicsBackend: .dxmt
        )
        let applicationID = UUID()
        let entry = LaunchEntry(
            applicationID: applicationID,
            executableURL: URL(filePath: "/tmp/Prefix/drive_c/Program Files/Steam/steam.exe")
        )
        let application = LibraryApplication(
            id: applicationID,
            environmentID: environment.id,
            name: "Steam",
            launchEntryIDs: [entry.id]
        )
        let records = [
            HostProcessSnapshot(
                processIdentifier: 10,
                residentMemoryKilobytes: 1_024,
                cpuPercent: 5,
                elapsedSeconds: 1,
                command: "C:\\Program Files\\Steam\\steam.exe WINEPREFIX=/tmp/Prefix"
            ),
            HostProcessSnapshot(
                processIdentifier: 11,
                residentMemoryKilobytes: 2_048,
                cpuPercent: 7.5,
                elapsedSeconds: 1,
                command: "C:\\Program Files\\Steam\\steamwebhelper.exe WINEPREFIX=/tmp/Prefix"
            )
        ]

        let snapshot = WineRuntimeProbe.performanceSnapshot(
            application: application,
            environment: environment,
            entry: entry,
            processes: records,
            launchLatency: 4
        )

        XCTAssertEqual(snapshot.processCount, 2)
        XCTAssertEqual(snapshot.cpuPercent, 12.5)
        XCTAssertEqual(snapshot.residentMemoryBytes, 3_145_728)
        XCTAssertEqual(snapshot.graphicsBackend, .dxmt)
        XCTAssertEqual(snapshot.launchLatency, 4)
    }

    func testPrefixMatchingRequiresExactEnvironmentValueBoundary() {
        let environment = WindowsEnvironment(
            name: "Primary",
            prefixURL: URL(filePath: "/tmp/Prefix")
        )
        let exact = HostProcessSnapshot(
            processIdentifier: 1,
            residentMemoryKilobytes: 1,
            cpuPercent: 0,
            elapsedSeconds: 1,
            command: "wineserver -w WINEPREFIX=/tmp/Prefix HOME=/tmp"
        )
        let backup = HostProcessSnapshot(
            processIdentifier: 2,
            residentMemoryKilobytes: 1,
            cpuPercent: 0,
            elapsedSeconds: 1,
            command: "wineserver -w WINEPREFIX=/tmp/Prefix-Backup HOME=/tmp"
        )
        let application = HostProcessSnapshot(
            processIdentifier: 3,
            residentMemoryKilobytes: 1,
            cpuPercent: 0,
            elapsedSeconds: 1,
            command: "C:\\Games\\game.exe",
            workingDirectoryPath: "/tmp/Prefix/drive_c/Games"
        )
        let backupApplication = HostProcessSnapshot(
            processIdentifier: 4,
            residentMemoryKilobytes: 1,
            cpuPercent: 0,
            elapsedSeconds: 1,
            command: "C:\\Games\\game.exe",
            workingDirectoryPath: "/tmp/Prefix-Backup/drive_c/Games"
        )

        XCTAssertTrue(WineRuntimeProbe.belongs(exact, to: environment))
        XCTAssertFalse(WineRuntimeProbe.belongs(backup, to: environment))
        XCTAssertTrue(WineRuntimeProbe.belongs(application, to: environment))
        XCTAssertFalse(WineRuntimeProbe.belongs(backupApplication, to: environment))
        XCTAssertEqual(
            WineRuntimeProbe.liveEnvironmentIDs(
                in: [backup],
                environments: [environment]
            ),
            []
        )
    }

    func testParsesWorkingDirectoriesFromNULTerminatedLsofFieldOutput() {
        let output = Data((
            "p101\0\nfcwd\0n/tmp/First Prefix/drive_c/Games\0\n"
                + "p202\0\nfcwd\0n/tmp/Second/drive_c/Program Files\0\n"
        ).utf8)

        XCTAssertEqual(
            WineRuntimeProbe.parseCurrentWorkingDirectories(output),
            [
                101: "/tmp/First Prefix/drive_c/Games",
                202: "/tmp/Second/drive_c/Program Files"
            ]
        )
    }

    func testNULTerminatedLsofParserPreservesNewlineInPath() {
        let output = Data("p101\0\nfcwd\0n/tmp/Prefix/line\nbreak\0\n".utf8)

        XCTAssertEqual(
            WineRuntimeProbe.parseCurrentWorkingDirectories(output)[101],
            "/tmp/Prefix/line\nbreak"
        )
    }

    func testNULTerminatedLsofParserIgnoresNameWithoutCwdField() {
        let output = Data("p101\0\nftxt\0n/tmp/not-cwd\0\nfcwd\0\n".utf8)

        XCTAssertTrue(WineRuntimeProbe.parseCurrentWorkingDirectories(output).isEmpty)
    }

    func testApplicationObservationUsesPrefixScopedWorkingDirectory() {
        let environment = WindowsEnvironment(
            name: "Steam",
            prefixURL: URL(filePath: "/tmp/Steam")
        )
        let applicationID = UUID()
        let entry = LaunchEntry(
            applicationID: applicationID,
            executableURL: URL(filePath: "/tmp/Steam/drive_c/Program Files/Steam/steam.exe")
        )
        let application = LibraryApplication(
            id: applicationID,
            environmentID: environment.id,
            name: "Steam",
            launchEntryIDs: [entry.id]
        )
        let records = [
            HostProcessSnapshot(
                processIdentifier: 10,
                residentMemoryKilobytes: 1,
                cpuPercent: 0,
                elapsedSeconds: 1,
                command: "wineserver -w WINEPREFIX=/tmp/Steam"
            ),
            HostProcessSnapshot(
                processIdentifier: 20,
                residentMemoryKilobytes: 1,
                cpuPercent: 0,
                elapsedSeconds: 1,
                command: "C:\\Program Files\\Steam\\steam.exe",
                workingDirectoryPath: "/tmp/Steam/drive_c/Program Files/Steam"
            )
        ]

        let observation = WineRuntimeProbe.observeApplications(
                in: records,
                environments: [environment],
                applications: [application],
                launchEntries: [entry]
            ).first
        XCTAssertEqual(observation?.processIdentifier, 20)
        XCTAssertEqual(observation?.relatedProcessIdentities.map(\.processIdentifier), [20])
    }

    func testApplicationObservationCannotCrossEnvironmentBoundary() {
        let first = WindowsEnvironment(name: "First", prefixURL: URL(filePath: "/tmp/First"))
        let second = WindowsEnvironment(name: "Second", prefixURL: URL(filePath: "/tmp/Second"))
        let applicationID = UUID()
        let entry = LaunchEntry(
            applicationID: applicationID,
            executableURL: URL(filePath: "/tmp/First/drive_c/Games/game.exe")
        )
        let application = LibraryApplication(
            id: applicationID,
            environmentID: first.id,
            name: "Game",
            launchEntryIDs: [entry.id]
        )
        let records = [
            HostProcessSnapshot(
                processIdentifier: 10,
                residentMemoryKilobytes: 1,
                cpuPercent: 0,
                elapsedSeconds: 1,
                command: "wineserver -w WINEPREFIX=/tmp/First"
            ),
            HostProcessSnapshot(
                processIdentifier: 20,
                residentMemoryKilobytes: 1,
                cpuPercent: 0,
                elapsedSeconds: 1,
                command: "C:\\Games\\game.exe WINEPREFIX=/tmp/Second"
            )
        ]

        XCTAssertTrue(WineRuntimeProbe.observeApplications(
            in: records,
            environments: [first, second],
            applications: [application],
            launchEntries: [entry]
        ).isEmpty)
    }

    func testRuntimeGuardRejectsUnattributedLiveWineServer() {
        let environment = WindowsEnvironment(
            name: "Running",
            prefixURL: URL(filePath: "/tmp/Running")
        )
        let process = HostProcessSnapshot(
            processIdentifier: 99,
            residentMemoryKilobytes: 1,
            cpuPercent: 0,
            elapsedSeconds: 1,
            command: "wineserver -w WINEPREFIX=/tmp/Running"
        )

        XCTAssertThrowsError(try WineRuntimeProbe.requireStopped(
            environmentID: environment.id,
            environments: [environment],
            processes: [process],
            sessions: []
        )) { error in
            XCTAssertEqual(error as? StillCoreError, .environmentMustBeStopped(environment.id))
        }
    }
}
