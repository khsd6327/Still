import Foundation

public actor LocalWineEngine: WineEngine {
    public nonisolated let descriptor: EngineDescriptor

    private let processSupervisor: ProcessSupervisor
    private let fileManager: FileManager
    private let logsRootURL: URL

    public init(
        descriptor: EngineDescriptor,
        processSupervisor: ProcessSupervisor = ProcessSupervisor(),
        fileManager: FileManager = .default,
        logsRootURL: URL = LogLocations.defaultRootURL()
    ) {
        self.descriptor = descriptor
        self.processSupervisor = processSupervisor
        self.fileManager = fileManager
        self.logsRootURL = logsRootURL
    }

    public func prepare(_ bottle: Bottle) async throws {
        try fileManager.createDirectory(
            at: bottle.prefixURL,
            withIntermediateDirectories: true
        )
        let sessionID = UUID()
        let logURL = LogLocations.launchLogURL(
            sessionID: sessionID,
            rootURL: logsRootURL
        )
        let plan = WineCommandBuilder.preparePlan(
            sessionID: sessionID,
            engine: descriptor,
            bottle: bottle,
            logURL: logURL
        )
        let exitCode = try await processSupervisor.runAndWait(plan)
        guard exitCode == 0 else {
            throw StillCoreError.processFailed(exitCode)
        }
    }

    public func launch(_ request: LaunchRequest) async throws -> LaunchSession {
        let sessionID = UUID()
        let plan = WineCommandBuilder.launchPlan(
            sessionID: sessionID,
            engine: descriptor,
            request: request,
            logURL: LogLocations.launchLogURL(
                sessionID: sessionID,
                rootURL: logsRootURL
            )
        )
        return try await processSupervisor.launch(plan)
    }

    public func stop(sessionID: LaunchSession.ID) async throws {
        try await processSupervisor.stop(sessionID: sessionID)
    }
}
