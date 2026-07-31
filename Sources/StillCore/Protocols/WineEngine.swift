import Foundation

public protocol WineEngine: Sendable {
    var descriptor: EngineDescriptor { get }

    func prepare(_ bottle: Bottle) async throws
    func launch(_ request: LaunchRequest) async throws -> LaunchSession
    func stop(sessionID: LaunchSession.ID) async throws
}

