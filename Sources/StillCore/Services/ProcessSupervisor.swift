import Darwin
import Foundation

public actor ProcessSupervisor {
    private struct ManagedProcess {
        var process: Process
        let logHandle: FileHandle
        let terminationPlan: ProcessTerminationPlan?
        var session: LaunchSession
    }

    private var processes: [LaunchSession.ID: ManagedProcess] = [:]
    private var completedSessions: [LaunchSession.ID: LaunchSession] = [:]
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func launch(_ plan: ProcessPlan) throws -> LaunchSession {
        try validate(plan)
        reapTerminatedProcesses()

        if let applicationID = plan.applicationID,
           processes.values.contains(where: {
               $0.session.applicationID == applicationID && $0.session.state.isActive
           }) {
            throw StillCoreError.duplicateLaunch(applicationID)
        }

        var managed = try makeManagedProcess(plan)
        try managed.session.transition(to: .launching)
        do {
            if let terminationPlan = managed.terminationPlan,
               let monitorExecutableURL = terminationPlan.monitorExecutableURL,
               !terminationPlan.monitorPrepareArguments.isEmpty {
                try runAndWait(
                    executableURL: monitorExecutableURL,
                    arguments: terminationPlan.monitorPrepareArguments,
                    environment: terminationPlan.environment,
                    workingDirectoryURL: terminationPlan.workingDirectoryURL,
                    logHandle: managed.logHandle,
                    acceptedExitCodes: terminationPlan.acceptedExitCodes
                )
            }
            try managed.process.run()
            if let terminationPlan = managed.terminationPlan,
               let monitorExecutableURL = terminationPlan.monitorExecutableURL {
                managed.process.waitUntilExit()
                guard terminationPlan.acceptedExitCodes.contains(
                    managed.process.terminationStatus
                ) else {
                    throw StillCoreError.processFailed(managed.process.terminationStatus)
                }
                managed.process = makeProcess(
                    executableURL: monitorExecutableURL,
                    arguments: terminationPlan.monitorArguments,
                    environment: terminationPlan.environment,
                    workingDirectoryURL: terminationPlan.workingDirectoryURL,
                    logHandle: managed.logHandle
                )
                try managed.process.run()
            }
            try managed.session.transition(
                to: .running,
                rootProcessIdentifier: managed.process.processIdentifier
            )
            managed.session.replaceAttributedProcesses([
                AttributedProcess(
                    processIdentifier: managed.process.processIdentifier,
                    name: managed.process.executableURL?.lastPathComponent ?? "Wine",
                    applicationID: plan.applicationID,
                    environmentID: plan.environmentID,
                    launchSessionID: plan.sessionID,
                    isRootProcess: true
                )
            ])
            processes[managed.session.id] = managed
            return managed.session
        } catch {
            try? managed.session.transition(
                to: .failed,
                failureDescription: error.localizedDescription
            )
            completedSessions[managed.session.id] = managed.session
            try? managed.logHandle.close()
            throw error
        }
    }

    public func adopt(
        _ plan: ProcessPlan,
        observedProcessIdentifier: Int32,
        observedProcessName: String
    ) throws -> LaunchSession {
        try validate(plan)
        reapTerminatedProcesses()
        if let applicationID = plan.applicationID,
           processes.values.contains(where: {
               $0.session.applicationID == applicationID && $0.session.state.isActive
           }) {
            throw StillCoreError.duplicateLaunch(applicationID)
        }
        guard let terminationPlan = plan.terminationPlan,
              let monitorExecutableURL = terminationPlan.monitorExecutableURL else {
            throw StillCoreError.invalidStore(
                "An adopted Wine session requires a prefix monitor."
            )
        }

        var managed = try makeManagedProcess(plan)
        managed.process = makeProcess(
            executableURL: monitorExecutableURL,
            arguments: terminationPlan.monitorArguments,
            environment: terminationPlan.environment,
            workingDirectoryURL: terminationPlan.workingDirectoryURL,
            logHandle: managed.logHandle
        )
        try managed.session.transition(to: .launching)
        do {
            try managed.process.run()
            try managed.session.transition(
                to: .running,
                rootProcessIdentifier: observedProcessIdentifier
            )
            managed.session.replaceAttributedProcesses([
                AttributedProcess(
                    processIdentifier: observedProcessIdentifier,
                    name: observedProcessName,
                    applicationID: plan.applicationID,
                    environmentID: plan.environmentID,
                    launchSessionID: plan.sessionID,
                    isRootProcess: true
                )
            ])
            processes[managed.session.id] = managed
            return managed.session
        } catch {
            try? managed.session.transition(
                to: .failed,
                failureDescription: error.localizedDescription
            )
            completedSessions[managed.session.id] = managed.session
            try? managed.logHandle.close()
            throw error
        }
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
        try terminate(sessionID: sessionID, force: false)
    }

    public func forceStop(sessionID: LaunchSession.ID) throws {
        try terminate(sessionID: sessionID, force: true)
    }

    public func stopAll() {
        terminateAll(force: false)
    }

    public func forceStopAll() {
        terminateAll(force: true)
    }

    public func session(id: LaunchSession.ID) -> LaunchSession? {
        reapTerminatedProcesses()
        return processes[id]?.session ?? completedSessions[id]
    }

    public func activeSessions() -> [LaunchSession] {
        reapTerminatedProcesses()
        return processes.values
            .map(\.session)
            .filter { $0.state.isActive }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func terminate(sessionID: LaunchSession.ID, force: Bool) throws {
        reapTerminatedProcesses()
        guard var managed = processes[sessionID] else {
            throw StillCoreError.sessionNotFound(sessionID)
        }
        guard managed.session.state == .running else {
            return
        }
        if let terminationPlan = managed.terminationPlan {
            try runTerminationPlan(
                terminationPlan,
                force: force,
                logURL: managed.session.logURL
            )
            let matchingIDs: [LaunchSession.ID]
            if terminationPlan.hostProcessPathPrefix == nil {
                matchingIDs = processes.compactMap { id, candidate in
                    candidate.terminationPlan?.scopeIdentifier
                        == terminationPlan.scopeIdentifier ? id : nil
                }
            } else {
                matchingIDs = [sessionID]
                if managed.process.isRunning {
                    if force {
                        Darwin.kill(managed.process.processIdentifier, SIGKILL)
                    } else {
                        managed.process.terminate()
                    }
                    managed.process.waitUntilExit()
                }
            }
            for id in matchingIDs {
                guard var candidate = processes[id], candidate.session.state == .running else {
                    continue
                }
                try candidate.session.transition(to: .stopping)
                processes[id] = candidate
            }
        } else {
            try managed.session.transition(to: .stopping)
            processes[sessionID] = managed
            if managed.process.isRunning {
                if force {
                    Darwin.kill(managed.process.processIdentifier, SIGKILL)
                } else {
                    managed.process.terminate()
                }
            }
        }
        reapTerminatedProcesses()
    }

    private func terminateAll(force: Bool) {
        reapTerminatedProcesses()
        let scopedPlans = Dictionary(grouping: processes.compactMap { id, managed in
            managed.terminationPlan.map { (id, $0) }
        }) { _, plan in
            plan.scopeIdentifier
        }
        var handledIDs = Set<LaunchSession.ID>()

        for (_, scopedEntries) in scopedPlans {
            guard let plan = scopedEntries.first?.1 else { continue }
            do {
                try runTerminationPlan(
                    plan,
                    force: force,
                    logURL: scopedEntries.first.flatMap { processes[$0.0]?.session.logURL },
                    respectHostProcessScope: false
                )
                for (id, _) in scopedEntries {
                    guard var managed = processes[id], managed.session.state == .running else {
                        continue
                    }
                    try managed.session.transition(to: .stopping)
                    processes[id] = managed
                    handledIDs.insert(id)
                }
            } catch {
                continue
            }
        }

        for id in Array(processes.keys) where !handledIDs.contains(id) {
            try? terminate(sessionID: id, force: force)
        }
        reapTerminatedProcesses()
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
        let process = makeProcess(
            executableURL: plan.executableURL,
            arguments: plan.arguments,
            environment: plan.environment,
            workingDirectoryURL: plan.workingDirectoryURL,
            logHandle: logHandle
        )

        return ManagedProcess(
            process: process,
            logHandle: logHandle,
            terminationPlan: plan.terminationPlan,
            session: LaunchSession(
                id: plan.sessionID,
                applicationID: plan.applicationID,
                environmentID: plan.environmentID,
                logURL: plan.logURL
            )
        )
    }

    private func makeProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectoryURL: URL?,
        logHandle: FileHandle
    ) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectoryURL
        process.standardOutput = logHandle
        process.standardError = logHandle
        return process
    }

    private func runTerminationPlan(
        _ plan: ProcessTerminationPlan,
        force: Bool,
        logURL: URL?,
        respectHostProcessScope: Bool = true
    ) throws {
        if respectHostProcessScope,
           let hostProcessPathPrefix = plan.hostProcessPathPrefix {
            _ = try HostProcessTerminator.terminateProcesses(
                matchingWindowsPathPrefix: hostProcessPathPrefix,
                force: force
            )
            return
        }
        let process = Process()
        process.executableURL = force
            ? plan.forceExecutableURL
            : plan.gracefulExecutableURL
        process.arguments = force ? plan.forceArguments : plan.gracefulArguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectoryURL
        var handle: FileHandle?
        if let logURL {
            handle = try FileHandle(forWritingTo: logURL)
            try handle?.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
        }
        defer { try? handle?.close() }
        guard let executableURL = process.executableURL,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw StillCoreError.engineBinaryUnavailable(
                process.executableURL ?? plan.gracefulExecutableURL
            )
        }
        try process.run()
        process.waitUntilExit()
        guard plan.acceptedExitCodes.contains(process.terminationStatus) else {
            throw StillCoreError.processFailed(process.terminationStatus)
        }
    }

    private func runAndWait(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectoryURL: URL?,
        logHandle: FileHandle,
        acceptedExitCodes: Set<Int32>
    ) throws {
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw StillCoreError.engineBinaryUnavailable(executableURL)
        }
        let process = makeProcess(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectoryURL: workingDirectoryURL,
            logHandle: logHandle
        )
        try process.run()
        process.waitUntilExit()
        guard acceptedExitCodes.contains(process.terminationStatus) else {
            throw StillCoreError.processFailed(process.terminationStatus)
        }
    }

    private func reapTerminatedProcesses() {
        let terminatedIDs = processes.compactMap { id, managed in
            managed.process.isRunning ? nil : id
        }
        for id in terminatedIDs {
            guard var managed = processes.removeValue(forKey: id) else { continue }
            if managed.session.state == .running {
                try? managed.session.transition(
                    to: .exited,
                    exitCode: managed.process.terminationStatus
                )
            } else if managed.session.state == .stopping {
                try? managed.session.transition(
                    to: .exited,
                    exitCode: managed.process.terminationStatus
                )
            }
            completedSessions[id] = managed.session
            try? managed.logHandle.close()
        }
    }
}
