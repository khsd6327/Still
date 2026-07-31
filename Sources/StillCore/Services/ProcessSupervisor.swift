import Foundation

public actor ProcessSupervisor {
    private struct ManagedProcess {
        let process: Process
        let logHandle: FileHandle
        let session: LaunchSession
    }

    private var processes: [LaunchSession.ID: ManagedProcess] = [:]
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func launch(_ plan: ProcessPlan) throws -> LaunchSession {
        try validate(plan)
        reapTerminatedProcesses()

        let managed = try makeManagedProcess(plan)
        try managed.process.run()
        processes[managed.session.id] = managed

        return LaunchSession(
            id: managed.session.id,
            processIdentifier: managed.process.processIdentifier,
            startedAt: managed.session.startedAt,
            logURL: managed.session.logURL
        )
    }

    @discardableResult
    public func runAndWait(_ plan: ProcessPlan) throws -> Int32 {
        try validate(plan)
        let managed = try makeManagedProcess(plan)
        try managed.process.run()
        managed.process.waitUntilExit()
        try? managed.logHandle.close()
        return managed.process.terminationStatus
    }

    public func stop(sessionID: LaunchSession.ID) throws {
        guard let managed = processes.removeValue(forKey: sessionID) else {
            throw StillCoreError.sessionNotFound(sessionID)
        }
        if managed.process.isRunning {
            managed.process.terminate()
        }
        try? managed.logHandle.close()
    }

    public func activeSessions() -> [LaunchSession] {
        reapTerminatedProcesses()
        return processes.values
            .map(\.session)
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func validate(_ plan: ProcessPlan) throws {
        guard fileManager.isExecutableFile(atPath: plan.executableURL.path) else {
            throw StillCoreError.engineBinaryUnavailable(plan.executableURL)
        }
    }

    private func makeManagedProcess(_ plan: ProcessPlan) throws -> ManagedProcess {
        try fileManager.createDirectory(
            at: plan.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: plan.logURL.path) {
            fileManager.createFile(atPath: plan.logURL.path, contents: nil)
        }

        let logHandle = try FileHandle(forWritingTo: plan.logURL)
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectoryURL
        process.standardOutput = logHandle
        process.standardError = logHandle

        let session = LaunchSession(
            id: plan.sessionID,
            processIdentifier: 0,
            logURL: plan.logURL
        )
        return ManagedProcess(
            process: process,
            logHandle: logHandle,
            session: session
        )
    }

    private func reapTerminatedProcesses() {
        let terminated = processes.filter { !$0.value.process.isRunning }
        for (id, managed) in terminated {
            try? managed.logHandle.close()
            processes.removeValue(forKey: id)
        }
    }
}
