import Foundation

public enum TerminationMode: String, Codable, Sendable {
    case normal
    case force
}

public enum TerminationScope: Hashable, Sendable {
    case session(LaunchSession.ID)
    case all
}

public actor TerminationCoordinator {
    private let supervisor: ProcessSupervisor

    public init(supervisor: ProcessSupervisor) {
        self.supervisor = supervisor
    }

    public func terminate(scope: TerminationScope, mode: TerminationMode) async throws {
        switch (scope, mode) {
        case (.session(let id), .normal):
            try await supervisor.stop(sessionID: id)
        case (.session(let id), .force):
            try await supervisor.forceStop(sessionID: id)
        case (.all, .normal):
            try await supervisor.stopAll()
        case (.all, .force):
            try await supervisor.forceStopAll()
        }
    }
}
