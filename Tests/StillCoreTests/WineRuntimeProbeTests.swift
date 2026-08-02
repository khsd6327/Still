import Foundation
import XCTest
@testable import StillCore

final class WineRuntimeProbeTests: XCTestCase {
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
                command: "/opt/wine/bin/wineserver -w WINEPREFIX=/tmp/Still Prefix"
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
                command: "C:\\Games\\Sample\\game.exe --play"
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
                command: "C:\\Program Files\\Steam\\steam.exe"
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
                command: "C:\\Program Files\\Steam\\steam.exe"
            ),
            HostProcessSnapshot(
                processIdentifier: 11,
                residentMemoryKilobytes: 2_048,
                cpuPercent: 7.5,
                elapsedSeconds: 1,
                command: "C:\\Program Files\\Steam\\steamwebhelper.exe"
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
}
