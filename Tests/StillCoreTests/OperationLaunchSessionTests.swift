import Foundation
import XCTest
@testable import StillCore

final class OperationLaunchSessionTests: XCTestCase {
    func testLaunchSessionSupportsCompleteAndFailureLifecycles() throws {
        var completed = LaunchSession(applicationID: UUID(), environmentID: UUID())
        try completed.transition(to: .launching)
        try completed.transition(to: .running, rootProcessIdentifier: 42)
        try completed.transition(to: .stopping)
        try completed.transition(to: .exited, exitCode: 0)
        XCTAssertEqual(completed.state, .exited)
        XCTAssertEqual(completed.processIdentifier, 42)
        XCTAssertEqual(completed.exitCode, 0)
        XCTAssertNotNil(completed.finishedAt)

        var failed = LaunchSession()
        try failed.transition(to: .launching)
        try failed.transition(to: .failed, failureDescription: "launch failed")
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failureDescription, "launch failed")
    }

    func testLaunchSessionRejectsInvalidTransition() throws {
        var session = LaunchSession()
        XCTAssertThrowsError(try session.transition(to: .running))
    }

    func testOperationLifecyclePersistsAndInterruptedWorkIsRecovered() async throws {
        let rootURL = temporaryRoot("OperationStore")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let environment = WindowsEnvironment(
            name: "Test",
            prefixURL: rootURL.appending(path: "Prefix")
        )
        let store = JSONStillStore(rootURL: rootURL)
        try await store.saveEnvironment(environment)

        var completed = StillOperation(kind: .backup, environmentID: environment.id)
        try completed.transition(to: .running)
        completed.updateProgress(1)
        completed.appendEvent("Backup complete")
        try completed.transition(to: .succeeded, resultSummary: "Saved")
        try await store.saveOperation(completed)

        var interrupted = StillOperation(kind: .repair, environmentID: environment.id)
        try interrupted.transition(to: .running)
        try await store.saveOperation(interrupted)
        let recovered = try await store.recoverInterruptedOperations()

        XCTAssertEqual(recovered.map(\.id), [interrupted.id])
        XCTAssertEqual(recovered.first?.state, .failed)
        let reloaded = try await store.operations(environmentID: environment.id)
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.first(where: { $0.id == completed.id })?.state, .succeeded)
        XCTAssertEqual(reloaded.first(where: { $0.id == interrupted.id })?.state, .failed)
    }

    func testRunningLaunchOperationIsRecoveredAsSuccessWhenApplicationIsObserved() async throws {
        let rootURL = temporaryRoot("RecoveredLaunch")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let environment = WindowsEnvironment(
            name: "Test",
            prefixURL: rootURL.appending(path: "Prefix")
        )
        let applicationID = UUID()
        let entry = LaunchEntry(
            applicationID: applicationID,
            executableURL: environment.prefixURL.appending(path: "drive_c/Game/game.exe")
        )
        let application = LibraryApplication(
            id: applicationID,
            environmentID: environment.id,
            name: "Game",
            launchEntryIDs: [entry.id]
        )
        let store = JSONStillStore(rootURL: rootURL)
        try await store.saveEnvironment(environment)
        try await store.saveApplication(application, launchEntries: [entry])
        var operation = StillOperation(
            kind: .launchApplication,
            environmentID: environment.id,
            applicationID: applicationID
        )
        try operation.transition(to: .running)
        try await store.saveOperation(operation)

        let recovered = try await store.recoverInterruptedOperations(
            activeApplicationIDs: [applicationID]
        )

        XCTAssertEqual(recovered.first?.state, .succeeded)
        XCTAssertEqual(recovered.first?.resultSummary, "Recovered running application after restart.")
    }

    func testEnvironmentRejectsConcurrentMutatingOperations() async throws {
        let environmentID = UUID()
        let first = StillOperation(kind: .repair, environmentID: environmentID)
        let second = StillOperation(kind: .backup, environmentID: environmentID)
        let coordinator = EnvironmentOperationCoordinator()

        try await coordinator.begin(first)
        do {
            try await coordinator.begin(second)
            XCTFail("Expected concurrent mutation rejection")
        } catch let error as StillCoreError {
            XCTAssertEqual(error, .environmentOperationInProgress(environmentID, first.id))
        }
        await coordinator.finish(first)
        try await coordinator.begin(second)
    }

    func testProcessAttributionUsesExplicitSessionScope() throws {
        let applicationID = UUID()
        let environmentID = UUID()
        var session = LaunchSession(
            applicationID: applicationID,
            environmentID: environmentID
        )
        try session.transition(to: .launching)
        try session.transition(to: .running, rootProcessIdentifier: 100)
        let attributed = ProcessAttributor().attribute(
            [
                WindowsProcess(name: "game.exe", processID: 100),
                WindowsProcess(name: "helper.exe", processID: 101)
            ],
            to: session
        )

        XCTAssertTrue(attributed[0].isRootProcess)
        XCTAssertFalse(attributed[1].isRootProcess)
        XCTAssertTrue(attributed.allSatisfy {
            $0.applicationID == applicationID
                && $0.environmentID == environmentID
                && $0.launchSessionID == session.id
        })
    }

    func testDuplicateApplicationLaunchIsRejected() async throws {
        let rootURL = temporaryRoot("DuplicateLaunch")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let applicationID = UUID()
        let supervisor = ProcessSupervisor()
        let first = ProcessPlan(
            applicationID: applicationID,
            environmentID: UUID(),
            executableURL: URL(filePath: "/bin/sleep"),
            arguments: ["5"],
            logURL: rootURL.appending(path: "first.log")
        )
        let second = ProcessPlan(
            applicationID: applicationID,
            environmentID: UUID(),
            executableURL: URL(filePath: "/bin/sleep"),
            arguments: ["5"],
            logURL: rootURL.appending(path: "second.log")
        )

        let firstSession = try await supervisor.launch(first)
        do {
            _ = try await supervisor.launch(second)
            XCTFail("Expected duplicate launch rejection")
        } catch let error as StillCoreError {
            XCTAssertEqual(error, .duplicateLaunch(applicationID))
        }
        try await supervisor.forceStop(sessionID: firstSession.id)
    }

    func testAllScopeTerminationTargetsEveryActiveSession() async throws {
        let rootURL = temporaryRoot("TerminateAll")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let supervisor = ProcessSupervisor()
        let coordinator = TerminationCoordinator(supervisor: supervisor)
        for index in 0..<2 {
            _ = try await supervisor.launch(ProcessPlan(
                applicationID: UUID(),
                environmentID: UUID(),
                executableURL: URL(filePath: "/bin/sleep"),
                arguments: ["5"],
                logURL: rootURL.appending(path: "\(index).log")
            ))
        }
        let initialActiveCount = await supervisor.activeSessions().count
        XCTAssertEqual(initialActiveCount, 2)
        try await coordinator.terminate(scope: .all, mode: .force)

        for _ in 0..<50 {
            if await supervisor.activeSessions().isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let isEmpty = await supervisor.activeSessions().isEmpty
        XCTAssertTrue(isEmpty)
    }

    func testForceStopAllDoesNotUseLegacyApplicationPathScope() async throws {
        let rootURL = temporaryRoot("PrefixForceStopAll")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let markerURL = rootURL.appending(path: "prefix-stopped")
        let termination = ProcessTerminationPlan(
            scopeIdentifier: rootURL.path,
            hostProcessPathPrefix: "C:\\Games\\One\\",
            gracefulExecutableURL: URL(filePath: "/usr/bin/touch"),
            gracefulArguments: [markerURL.path],
            forceExecutableURL: URL(filePath: "/usr/bin/touch"),
            forceArguments: [markerURL.path],
            environment: [:],
            workingDirectoryURL: rootURL,
            acceptedExitCodes: [0]
        )
        let supervisor = ProcessSupervisor()
        _ = try await supervisor.launch(ProcessPlan(
            applicationID: UUID(),
            environmentID: UUID(),
            executableURL: URL(filePath: "/bin/sleep"),
            arguments: ["0.1"],
            logURL: rootURL.appending(path: "launch.log"),
            terminationPlan: termination
        ))

        try await supervisor.forceStopAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        try await Task.sleep(for: .milliseconds(150))
        let activeSessions = await supervisor.activeSessions()
        XCTAssertTrue(activeSessions.isEmpty)
    }

    func testWineTerminationMarksEverySessionInThePrefixStopping() async throws {
        let rootURL = temporaryRoot("WineScope")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let supervisor = ProcessSupervisor()
        let stopMarkerURL = rootURL.appending(path: "stop")
        let monitorScript = "while [ ! -f \"$1\" ]; do sleep 0.01; done"
        let termination = ProcessTerminationPlan(
            scopeIdentifier: rootURL.path,
            gracefulExecutableURL: URL(filePath: "/usr/bin/touch"),
            gracefulArguments: [stopMarkerURL.path],
            forceExecutableURL: URL(filePath: "/usr/bin/touch"),
            forceArguments: [stopMarkerURL.path],
            monitorExecutableURL: URL(filePath: "/bin/sh"),
            monitorArguments: ["-c", monitorScript, "monitor", stopMarkerURL.path],
            environment: [:],
            workingDirectoryURL: rootURL,
            acceptedExitCodes: [0]
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let firstPlan = ProcessPlan(
            applicationID: UUID(),
            environmentID: UUID(),
            executableURL: URL(filePath: "/usr/bin/true"),
            arguments: [],
            logURL: rootURL.appending(path: "first.log"),
            terminationPlan: termination
        )
        let secondPlan = ProcessPlan(
            applicationID: UUID(),
            environmentID: UUID(),
            executableURL: URL(filePath: "/usr/bin/true"),
            arguments: [],
            logURL: rootURL.appending(path: "second.log"),
            terminationPlan: termination
        )
        let first = try await supervisor.adopt(
            firstPlan,
            observedProcessIdentifier: 100,
            observedProcessName: "first.exe"
        )
        let second = try await supervisor.adopt(
            secondPlan,
            observedProcessIdentifier: 101,
            observedProcessName: "second.exe"
        )

        try await supervisor.stop(sessionID: first.id)

        let firstState = await supervisor.session(id: first.id)?.state
        let secondState = await supervisor.session(id: second.id)?.state
        XCTAssertTrue(firstState == .stopping || firstState == .exited)
        XCTAssertTrue(secondState == .stopping || secondState == .exited)
        for _ in 0..<50 {
            if await supervisor.activeSessions().isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let activeSessions = await supervisor.activeSessions()
        XCTAssertTrue(activeSessions.isEmpty)
    }

    func testApplicationScopedTerminationLeavesOtherSessionRunning() async throws {
        let rootURL = temporaryRoot("ApplicationScope")
        let firstExecutableURL = rootURL.appending(path: "first/sleep")
        let secondExecutableURL = rootURL.appending(path: "second/sleep")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: firstExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: firstExecutableURL)
        try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: secondExecutableURL)

        let supervisor = ProcessSupervisor()
        let first = try await supervisor.launch(ProcessPlan(
            applicationID: UUID(),
            environmentID: UUID(),
            executableURL: firstExecutableURL,
            arguments: ["5"],
            logURL: rootURL.appending(path: "first.log"),
            terminationPlan: ProcessTerminationPlan(
                scopeIdentifier: rootURL.path,
                hostProcessPathPrefix: firstExecutableURL.path,
                gracefulExecutableURL: URL(filePath: "/usr/bin/true"),
                gracefulArguments: [],
                forceExecutableURL: URL(filePath: "/usr/bin/true"),
                forceArguments: [],
                environment: [:]
            )
        ))
        let second = try await supervisor.launch(ProcessPlan(
            applicationID: UUID(),
            environmentID: UUID(),
            executableURL: secondExecutableURL,
            arguments: ["5"],
            logURL: rootURL.appending(path: "second.log")
        ))

        try await supervisor.stop(sessionID: first.id)

        for _ in 0..<50 {
            if await supervisor.session(id: first.id)?.state == .exited { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstState = await supervisor.session(id: first.id)?.state
        let secondState = await supervisor.session(id: second.id)?.state
        XCTAssertEqual(firstState, .exited)
        XCTAssertEqual(secondState, .running)
        try await supervisor.forceStop(sessionID: second.id)
    }

    func testCompletedSessionCannotReplayItsTerminationPlan() async throws {
        let rootURL = temporaryRoot("ExitedMonitor")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let markerURL = rootURL.appending(path: "stopped")
        let termination = ProcessTerminationPlan(
            scopeIdentifier: rootURL.path,
            gracefulExecutableURL: URL(filePath: "/usr/bin/touch"),
            gracefulArguments: [markerURL.path],
            forceExecutableURL: URL(filePath: "/usr/bin/touch"),
            forceArguments: [markerURL.path],
            monitorExecutableURL: URL(filePath: "/usr/bin/true"),
            environment: [:],
            workingDirectoryURL: rootURL,
            acceptedExitCodes: [0]
        )
        let supervisor = ProcessSupervisor()
        let session = try await supervisor.launch(ProcessPlan(
            applicationID: UUID(),
            environmentID: UUID(),
            executableURL: URL(filePath: "/usr/bin/true"),
            arguments: [],
            logURL: rootURL.appending(path: "launch.log"),
            terminationPlan: termination
        ))
        try await Task.sleep(for: .milliseconds(20))
        _ = await supervisor.session(id: session.id)

        do {
            try await supervisor.stop(sessionID: session.id)
            XCTFail("Expected completed session rejection")
        } catch let error as StillCoreError {
            XCTAssertEqual(error, .sessionNotFound(session.id))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testMonitorPreparationRunsBeforeAsynchronousSessionMonitor() async throws {
        let rootURL = temporaryRoot("MonitorPreparation")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let markerURL = rootURL.appending(path: "prepared")
        let monitorScript = "test -f \"$1\" && sleep 0.2"
        let termination = ProcessTerminationPlan(
            scopeIdentifier: rootURL.path,
            gracefulExecutableURL: URL(filePath: "/usr/bin/true"),
            gracefulArguments: [],
            forceExecutableURL: URL(filePath: "/usr/bin/true"),
            forceArguments: [],
            monitorExecutableURL: URL(filePath: "/bin/sh"),
            monitorPrepareArguments: ["-c", "touch \"$1\"", "prepare", markerURL.path],
            monitorArguments: ["-c", monitorScript, "monitor", markerURL.path],
            environment: [:],
            workingDirectoryURL: rootURL,
            acceptedExitCodes: [0]
        )
        let supervisor = ProcessSupervisor()
        let session = try await supervisor.launch(ProcessPlan(
            applicationID: UUID(),
            environmentID: UUID(),
            executableURL: URL(filePath: "/usr/bin/true"),
            arguments: [],
            logURL: rootURL.appending(path: "launch.log"),
            terminationPlan: termination
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        let confirmed = try await supervisor.confirmRunning(
            sessionID: session.id,
            observation: LiveWineApplicationObservation(
                applicationID: session.applicationID!,
                environmentID: session.environmentID!,
                processIdentifier: 321,
                processName: "game.exe"
            )
        )
        let runningState = confirmed.state
        XCTAssertEqual(runningState, .running)
        try await Task.sleep(for: .milliseconds(250))
        let activeSessions = await supervisor.activeSessions()
        XCTAssertTrue(activeSessions.isEmpty)
    }

    func testAdoptedWineSessionIsActiveAndRejectsDuplicateApplication() async throws {
        let rootURL = temporaryRoot("AdoptedSession")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let applicationID = UUID()
        let termination = ProcessTerminationPlan(
            scopeIdentifier: rootURL.path,
            gracefulExecutableURL: URL(filePath: "/usr/bin/true"),
            gracefulArguments: [],
            forceExecutableURL: URL(filePath: "/usr/bin/true"),
            forceArguments: [],
            monitorExecutableURL: URL(filePath: "/bin/sleep"),
            monitorArguments: ["2"],
            environment: [:],
            workingDirectoryURL: rootURL,
            acceptedExitCodes: [0]
        )
        let plan = ProcessPlan(
            applicationID: applicationID,
            environmentID: UUID(),
            executableURL: URL(filePath: "/usr/bin/true"),
            arguments: [],
            logURL: rootURL.appending(path: "adopted.log"),
            terminationPlan: termination
        )
        let supervisor = ProcessSupervisor()

        let session = try await supervisor.adopt(
            plan,
            observedProcessIdentifier: 321,
            observedProcessName: "game.exe"
        )

        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.processIdentifier, 321)
        XCTAssertEqual(session.attributedProcesses.first?.name, "game.exe")
        do {
            _ = try await supervisor.adopt(
                plan,
                observedProcessIdentifier: 322,
                observedProcessName: "game.exe"
            )
            XCTFail("Expected duplicate adopted session rejection")
        } catch let error as StillCoreError {
            XCTAssertEqual(error, .duplicateLaunch(applicationID))
        }
        try await supervisor.forceStop(sessionID: session.id)
    }

    func testReconcileRejectsReusedProcessIdentifier() async throws {
        let rootURL = temporaryRoot("PIDReuse")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let applicationID = UUID()
        let environmentID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let termination = ProcessTerminationPlan(
            scopeIdentifier: rootURL.path,
            gracefulExecutableURL: URL(filePath: "/usr/bin/true"),
            gracefulArguments: [],
            forceExecutableURL: URL(filePath: "/usr/bin/true"),
            forceArguments: [],
            monitorExecutableURL: URL(filePath: "/bin/sleep"),
            monitorArguments: ["2"],
            environment: [:],
            workingDirectoryURL: rootURL,
            acceptedExitCodes: [0]
        )
        let supervisor = ProcessSupervisor()
        let session = try await supervisor.adopt(
            ProcessPlan(
                applicationID: applicationID,
                environmentID: environmentID,
                executableURL: URL(filePath: "/usr/bin/true"),
                arguments: [],
                logURL: rootURL.appending(path: "pid-reuse.log"),
                terminationPlan: termination
            ),
            observedProcessIdentifier: 321,
            observedProcessName: "game.exe",
            observedProcessStartedAt: startedAt
        )

        await supervisor.reconcileApplications([
            LiveWineApplicationObservation(
                applicationID: applicationID,
                environmentID: environmentID,
                processIdentifier: 321,
                processName: "replacement.exe",
                processIdentity: HostProcessIdentity(
                    processIdentifier: 321,
                    startedAt: startedAt.addingTimeInterval(5)
                )
            )
        ])

        let reconciledState = await supervisor.session(id: session.id)?.state
        XCTAssertEqual(reconciledState, .exited)
        let activeSessions = await supervisor.activeSessions()
        XCTAssertTrue(activeSessions.isEmpty)
    }

    private func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "Still\(name)Tests")
            .appending(path: UUID().uuidString)
    }
}
