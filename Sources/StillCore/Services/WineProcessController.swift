import Foundation

public actor WineProcessController {
    private let processSupervisor: ProcessSupervisor
    private let logsRootURL: URL

    public init(
        processSupervisor: ProcessSupervisor = ProcessSupervisor(),
        logsRootURL: URL = LogLocations.defaultRootURL()
    ) {
        self.processSupervisor = processSupervisor
        self.logsRootURL = logsRootURL
    }

    public func stop(
        bottle: Bottle,
        engine: EngineDescriptor
    ) async throws {
        let sessionID = UUID()
        let exitCode = try await processSupervisor.runAndWait(
            WineCommandBuilder.stopPlan(
                sessionID: sessionID,
                engine: engine,
                bottle: bottle,
                logURL: LogLocations.launchLogURL(
                    sessionID: sessionID,
                    rootURL: logsRootURL
                )
            )
        )
        // WineServer returns 1 when the bottle has no running server.
        // The requested stopped state has already been reached in that case.
        guard exitCode == 0 || exitCode == 1 else {
            throw StillCoreError.processFailed(exitCode)
        }
    }

    public func forceStop(
        bottle: Bottle,
        engine: EngineDescriptor
    ) async throws {
        let sessionID = UUID()
        let exitCode = try await processSupervisor.runAndWait(
            WineCommandBuilder.forceStopPlan(
                sessionID: sessionID,
                engine: engine,
                bottle: bottle,
                logURL: LogLocations.launchLogURL(
                    sessionID: sessionID,
                    rootURL: logsRootURL
                )
            )
        )
        guard exitCode == 0 || exitCode == 1 else {
            throw StillCoreError.processFailed(exitCode)
        }
    }

    @discardableResult
    public func launchTool(
        _ arguments: [String],
        bottle: Bottle,
        engine: EngineDescriptor
    ) async throws -> LaunchSession {
        let sessionID = UUID()
        return try await processSupervisor.launch(
            WineCommandBuilder.utilityPlan(
                sessionID: sessionID,
                engine: engine,
                bottle: bottle,
                arguments: arguments,
                logURL: LogLocations.launchLogURL(
                    sessionID: sessionID,
                    rootURL: logsRootURL
                )
            )
        )
    }

    public func processes(
        bottle: Bottle,
        engine: EngineDescriptor
    ) async throws -> [WindowsProcess] {
        let sessionID = UUID()
        let logURL = LogLocations.launchLogURL(
            sessionID: sessionID,
            rootURL: logsRootURL
        )
        let exitCode = try await processSupervisor.runAndWait(
            WineCommandBuilder.utilityPlan(
                sessionID: sessionID,
                engine: engine,
                bottle: bottle,
                arguments: ["tasklist.exe", "/FO", "CSV", "/NH"],
                logURL: logURL
            )
        )
        guard exitCode == 0 else {
            throw StillCoreError.processFailed(exitCode)
        }
        let output = try String(contentsOf: logURL, encoding: .utf8)
        return WindowsProcessListParser.parse(output)
    }

    public func kill(
        processID: Int32,
        bottle: Bottle,
        engine: EngineDescriptor
    ) async throws {
        let sessionID = UUID()
        let exitCode = try await processSupervisor.runAndWait(
            WineCommandBuilder.utilityPlan(
                sessionID: sessionID,
                engine: engine,
                bottle: bottle,
                arguments: [
                    "taskkill.exe",
                    "/PID",
                    String(processID),
                    "/F"
                ],
                logURL: LogLocations.launchLogURL(
                    sessionID: sessionID,
                    rootURL: logsRootURL
                )
            )
        )
        guard exitCode == 0 else {
            throw StillCoreError.processFailed(exitCode)
        }
    }
}
