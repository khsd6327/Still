import Foundation

public struct ProcessPlan: Sendable {
    public let sessionID: UUID
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectoryURL: URL?
    public let logURL: URL

    public init(
        sessionID: UUID = UUID(),
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectoryURL: URL? = nil,
        logURL: URL
    ) {
        self.sessionID = sessionID
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.logURL = logURL
    }
}
