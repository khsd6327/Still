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

    private func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "Still\(name)Tests")
            .appending(path: UUID().uuidString)
    }
}
