import Foundation

public struct LaunchRequest: Hashable, Sendable {
    public let bottle: Bottle
    public let executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectoryURL: URL?

    public init(
        bottle: Bottle,
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectoryURL: URL? = nil
    ) {
        self.bottle = bottle
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
    }
}

public struct LaunchSession: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let processIdentifier: Int32
    public let startedAt: Date
    public let logURL: URL?

    public init(
        id: UUID = UUID(),
        processIdentifier: Int32,
        startedAt: Date = .now,
        logURL: URL? = nil
    ) {
        self.id = id
        self.processIdentifier = processIdentifier
        self.startedAt = startedAt
        self.logURL = logURL
    }
}

