import Darwin
import Foundation

public actor ProcessSupervisor {
    private struct ManagedSession {
        var process: Process?
        var logHandle: FileHandle?
        let terminationPlan: ProcessTerminationPlan?
        var session: LaunchSession
    }

    private struct EnvironmentMonitor {
        let process: Process
        let logHandle: FileHandle
        let plan: ProcessTerminationPlan
    }

    private var sessions: [LaunchSession.ID: ManagedSession] = [:]
    private var monitors: [String: EnvironmentMonitor] = [:]
    private var completedSessions: [LaunchSession.ID: LaunchSession] = [:]
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func launch(_ plan: ProcessPlan) throws -> LaunchSession {
        try validate(plan)
        reapTerminatedState()
        try rejectDuplicateApplication(plan.applicationID)

        var managed = try makeManagedSession(plan)
        try managed.session.transition(to: .launching)
        do {
            guard let terminationPlan = plan.terminationPlan,
                  terminationPlan.monitorExecutableURL != nil else {
                guard let process = managed.process else {
                    throw StillCoreError.invalidStore("The launch process was not prepared.")
                }
                try process.run()
                try managed.session.transition(
                    to: .running,
                    rootProcessIdentifier: process.processIdentifier
                )
                managed.session.replaceAttributedProcesses([
                    AttributedProcess(
                        processIdentifier: process.processIdentifier,
                        name: process.executableURL?.lastPathComponent ?? "Process",
                        applicationID: plan.applicationID,
                        environmentID: plan.environmentID,
                        launchSessionID: plan.sessionID,
                        isRootProcess: true
                    )
                ])
                sessions[managed.session.id] = managed
                return managed.session
            }

            guard let logHandle = managed.logHandle,
                  let launchProcess = managed.process else {
                throw StillCoreError.invalidStore("The Wine launch process was not prepared.")
            }
            if !terminationPlan.monitorPrepareArguments.isEmpty,
               monitors[terminationPlan.scopeIdentifier] == nil,
               let monitorExecutableURL = terminationPlan.monitorExecutableURL {
                try runAndWait(
                    executableURL: monitorExecutableURL,
                    arguments: terminationPlan.monitorPrepareArguments,
                    environment: terminationPlan.environment,
                    workingDirectoryURL: terminationPlan.workingDirectoryURL,
                    logHandle: logHandle,
                    acceptedExitCodes: terminationPlan.acceptedExitCodes
                )
            }
            try launchProcess.run()
            launchProcess.waitUntilExit()
            guard terminationPlan.acceptedExitCodes.contains(launchProcess.terminationStatus) else {
                throw StillCoreError.processFailed(launchProcess.terminationStatus)
            }
            try? logHandle.close()
            managed.process = nil
            managed.logHandle = nil
            try ensureEnvironmentMonitor(terminationPlan, logURL: plan.logURL)
            sessions[managed.session.id] = managed
            return managed.session
        } catch {
            fail(&managed, error: error)
            throw error
        }
    }

    public func confirmRunning(
        sessionID: LaunchSession.ID,
        observation: LiveWineApplicationObservation
    ) throws -> LaunchSession {
        reapTerminatedState()
        guard var managed = sessions[sessionID] else {
            throw StillCoreError.sessionNotFound(sessionID)
        }
        guard managed.session.state == .launching,
              managed.session.applicationID == observation.applicationID,
              managed.session.environmentID == observation.environmentID else {
            throw StillCoreError.invalidApplicationState(managed.session.state.rawValue)
        }
        try managed.session.transition(
            to: .running,
            rootProcessIdentifier: observation.processIdentifier,
            rootProcessStartedAt: observation.processIdentity.startedAt
        )
        managed.session.replaceAttributedProcesses([
            AttributedProcess(
                processIdentifier: observation.processIdentifier,
                name: observation.processName,
                applicationID: observation.applicationID,
                environmentID: observation.environmentID,
                launchSessionID: sessionID,
                isRootProcess: true,
                processStartedAt: observation.processIdentity.startedAt
            )
        ])
        sessions[sessionID] = managed
        return managed.session
    }

    public func failLaunch(sessionID: LaunchSession.ID, reason: String) {
        guard var managed = sessions.removeValue(forKey: sessionID) else { return }
        if managed.session.state == .launching {
            try? managed.session.transition(to: .failed, failureDescription: reason)
        }
        closeResources(&managed)
        completedSessions[sessionID] = managed.session
    }

    public func adopt(
        _ plan: ProcessPlan,
        observedProcessIdentifier: Int32,
        observedProcessName: String,
        observedProcessStartedAt: Date? = nil
    ) throws -> LaunchSession {
        try validate(plan)
        reapTerminatedState()
        try rejectDuplicateApplication(plan.applicationID)
        guard let terminationPlan = plan.terminationPlan,
              terminationPlan.monitorExecutableURL != nil else {
            throw StillCoreError.invalidStore("An adopted Wine session requires a prefix monitor.")
        }

        var managed = try makeManagedSession(plan)
        try managed.session.transition(to: .launching)
        do {
            closeResources(&managed)
            try ensureEnvironmentMonitor(terminationPlan, logURL: plan.logURL)
            try managed.session.transition(
                to: .running,
                rootProcessIdentifier: observedProcessIdentifier,
                rootProcessStartedAt: observedProcessStartedAt
            )
            managed.session.replaceAttributedProcesses([
                AttributedProcess(
                    processIdentifier: observedProcessIdentifier,
                    name: observedProcessName,
                    applicationID: plan.applicationID,
                    environmentID: plan.environmentID,
                    launchSessionID: plan.sessionID,
                    isRootProcess: true,
                    processStartedAt: observedProcessStartedAt
                )
            ])
            sessions[managed.session.id] = managed
            return managed.session
        } catch {
            fail(&managed, error: error)
            throw error
        }
    }

    public func reconcileApplications(_ observations: [LiveWineApplicationObservation]) {
        reapTerminatedState()
        let byApplication = Dictionary(uniqueKeysWithValues: observations.map {
            ($0.applicationID, $0)
        })
        for id in Array(sessions.keys) {
            guard var managed = sessions[id],
                  managed.terminationPlan != nil,
                  managed.session.state == .running,
                  let applicationID = managed.session.applicationID else { continue }
            guard let observation = byApplication[applicationID],
                  managed.session.environmentID == observation.environmentID,
                  managed.session.rootProcessIdentifier == observation.processIdentifier,
                  startTimesMatch(
                    managed.session.rootProcessStartedAt,
                    observation.processIdentity.startedAt
                  ) else {
                sessions.removeValue(forKey: id)
                try? managed.session.transition(to: .exited)
                completedSessions[id] = managed.session
                continue
            }
        }
    }

    @discardableResult
    public func runAndWait(_ plan: ProcessPlan) throws -> Int32 {
        try validate(plan)
        var managed = try makeManagedSession(plan)
        guard let process = managed.process else {
            throw StillCoreError.invalidStore("The process was not prepared.")
        }
        try process.run()
        process.waitUntilExit()
        closeResources(&managed)
        return process.terminationStatus
    }

    public func stop(sessionID: LaunchSession.ID) throws {
        try terminate(sessionID: sessionID, force: false)
    }

    public func forceStop(sessionID: LaunchSession.ID) throws {
        try terminate(sessionID: sessionID, force: true)
    }

    public func stopAll() throws {
        try terminateAll(force: false)
    }

    public func forceStopAll() throws {
        try terminateAll(force: true)
    }

    public func session(id: LaunchSession.ID) -> LaunchSession? {
        reapTerminatedState()
        return sessions[id]?.session ?? completedSessions[id]
    }

    public func activeSessions() -> [LaunchSession] {
        reapTerminatedState()
        return sessions.values
            .map(\.session)
            .filter { $0.state.isActive }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func terminate(sessionID: LaunchSession.ID, force: Bool) throws {
        reapTerminatedState()
        guard let managed = sessions[sessionID] else {
            throw StillCoreError.sessionNotFound(sessionID)
        }
        guard managed.session.state.isActive else { return }
        if let plan = managed.terminationPlan,
           plan.monitorExecutableURL != nil {
            try runTerminationPlan(plan, force: force, logURL: managed.session.logURL)
            try markScopeStopping(plan.scopeIdentifier)
        } else {
            guard var candidate = sessions[sessionID] else { return }
            if candidate.session.state == .running || candidate.session.state == .launching {
                try candidate.session.transition(to: .stopping)
            }
            if let process = candidate.process, process.isRunning {
                if force {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                } else {
                    process.terminate()
                }
            }
            sessions[sessionID] = candidate
        }
        reapTerminatedState()
    }

    private func terminateAll(force: Bool) throws {
        reapTerminatedState()
        let scopedPlans = Dictionary(
            grouping: sessions.values.compactMap {
                $0.terminationPlan?.monitorExecutableURL == nil ? nil : $0.terminationPlan
            },
            by: \.scopeIdentifier
        )
        var failures: [String] = []
        for (scope, plans) in scopedPlans {
            guard let plan = plans.first else { continue }
            do {
                let logURL = sessions.values.first {
                    $0.terminationPlan?.scopeIdentifier == scope
                }?.session.logURL
                try runTerminationPlan(plan, force: force, logURL: logURL)
                try markScopeStopping(scope)
            } catch {
                failures.append("\(scope): \(error.localizedDescription)")
            }
        }
        for id in Array(sessions.keys) where sessions[id]?.terminationPlan?.monitorExecutableURL == nil {
            do {
                try terminate(sessionID: id, force: force)
            } catch {
                failures.append("\(id): \(error.localizedDescription)")
            }
        }
        reapTerminatedState()
        if !failures.isEmpty { throw StillCoreError.terminationFailed(failures) }
    }

    private func markScopeStopping(_ scopeIdentifier: String) throws {
        for id in Array(sessions.keys) {
            guard var managed = sessions[id],
                  managed.terminationPlan?.scopeIdentifier == scopeIdentifier,
                  managed.session.state == .running || managed.session.state == .launching else {
                continue
            }
            try managed.session.transition(to: .stopping)
            sessions[id] = managed
        }
    }

    private func rejectDuplicateApplication(_ applicationID: LibraryApplication.ID?) throws {
        if let applicationID,
           sessions.values.contains(where: {
               $0.session.applicationID == applicationID && $0.session.state.isActive
           }) {
            throw StillCoreError.duplicateLaunch(applicationID)
        }
    }

    private func validate(_ plan: ProcessPlan) throws {
        guard fileManager.isExecutableFile(atPath: plan.executableURL.path) else {
            throw StillCoreError.engineBinaryUnavailable(plan.executableURL)
        }
    }

    private func makeManagedSession(_ plan: ProcessPlan) throws -> ManagedSession {
        try fileManager.createDirectory(
            at: plan.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: plan.logURL.path) {
            fileManager.createFile(atPath: plan.logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: plan.logURL)
        return ManagedSession(
            process: makeProcess(
                executableURL: plan.executableURL,
                arguments: plan.arguments,
                environment: plan.environment,
                workingDirectoryURL: plan.workingDirectoryURL,
                logHandle: logHandle
            ),
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

    private func ensureEnvironmentMonitor(
        _ plan: ProcessTerminationPlan,
        logURL: URL
    ) throws {
        if let existing = monitors[plan.scopeIdentifier], existing.process.isRunning { return }
        if let stale = monitors.removeValue(forKey: plan.scopeIdentifier) {
            try? stale.logHandle.close()
        }
        guard let executableURL = plan.monitorExecutableURL else {
            throw StillCoreError.invalidStore("The Environment monitor is unavailable.")
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        let process = makeProcess(
            executableURL: executableURL,
            arguments: plan.monitorArguments,
            environment: plan.environment,
            workingDirectoryURL: plan.workingDirectoryURL,
            logHandle: handle
        )
        do {
            try process.run()
            monitors[plan.scopeIdentifier] = EnvironmentMonitor(
                process: process,
                logHandle: handle,
                plan: plan
            )
        } catch {
            try? handle.close()
            throw error
        }
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
        logURL: URL?
    ) throws {
        let process = Process()
        process.executableURL = force ? plan.forceExecutableURL : plan.gracefulExecutableURL
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

    private func reapTerminatedState() {
        let stoppedScopes = monitors.compactMap { scope, monitor in
            monitor.process.isRunning ? nil : scope
        }
        for scope in stoppedScopes {
            guard let monitor = monitors.removeValue(forKey: scope) else { continue }
            try? monitor.logHandle.close()
            for id in Array(sessions.keys) {
                guard var managed = sessions[id],
                      managed.terminationPlan?.scopeIdentifier == scope else { continue }
                sessions.removeValue(forKey: id)
                if managed.session.state == .launching {
                    try? managed.session.transition(
                        to: .failed,
                        failureDescription: "The Environment monitor exited before the application was observed."
                    )
                } else if managed.session.state == .running || managed.session.state == .stopping {
                    try? managed.session.transition(
                        to: .exited,
                        exitCode: monitor.process.terminationStatus
                    )
                }
                completedSessions[id] = managed.session
            }
        }

        for id in Array(sessions.keys) {
            guard var managed = sessions[id],
                  managed.terminationPlan?.monitorExecutableURL == nil,
                  let process = managed.process,
                  !process.isRunning else { continue }
            sessions.removeValue(forKey: id)
            if managed.session.state == .running || managed.session.state == .stopping {
                try? managed.session.transition(
                    to: .exited,
                    exitCode: process.terminationStatus
                )
            }
            closeResources(&managed)
            completedSessions[id] = managed.session
        }
    }

    private func fail(_ managed: inout ManagedSession, error: Error) {
        if managed.session.state == .launching {
            try? managed.session.transition(
                to: .failed,
                failureDescription: error.localizedDescription
            )
        }
        closeResources(&managed)
        completedSessions[managed.session.id] = managed.session
    }

    private func closeResources(_ managed: inout ManagedSession) {
        if let process = managed.process, process.isRunning { process.terminate() }
        try? managed.logHandle?.close()
        managed.process = nil
        managed.logHandle = nil
    }

    private func startTimesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return true }
        return abs(lhs.timeIntervalSince(rhs)) <= 2
    }
}
