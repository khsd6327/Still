import Foundation

public struct ProcessPlan: Sendable {
    public let sessionID: UUID
    public let applicationID: LibraryApplication.ID?
    public let environmentID: WindowsEnvironment.ID?
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectoryURL: URL?
    public let logURL: URL

    public init(
        sessionID: UUID = UUID(),
        applicationID: LibraryApplication.ID? = nil,
        environmentID: WindowsEnvironment.ID? = nil,
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectoryURL: URL? = nil,
        logURL: URL
    ) {
        self.sessionID = sessionID
        self.applicationID = applicationID
        self.environmentID = environmentID
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.logURL = logURL
    }
}
