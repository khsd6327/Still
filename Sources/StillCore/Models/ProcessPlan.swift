import Foundation

public struct ProcessTerminationPlan: Sendable {
    public let scopeIdentifier: String
    public let hostProcessPathPrefix: String?
    public let gracefulExecutableURL: URL
    public let gracefulArguments: [String]
    public let forceExecutableURL: URL
    public let forceArguments: [String]
    public let monitorExecutableURL: URL?
    public let monitorArguments: [String]
    public let environment: [String: String]
    public let workingDirectoryURL: URL?
    public let acceptedExitCodes: Set<Int32>

    public init(
        scopeIdentifier: String,
        hostProcessPathPrefix: String? = nil,
        gracefulExecutableURL: URL,
        gracefulArguments: [String],
        forceExecutableURL: URL,
        forceArguments: [String],
        monitorExecutableURL: URL? = nil,
        monitorArguments: [String] = [],
        environment: [String: String],
        workingDirectoryURL: URL? = nil,
        acceptedExitCodes: Set<Int32> = [0, 1]
    ) {
        self.scopeIdentifier = scopeIdentifier
        self.hostProcessPathPrefix = hostProcessPathPrefix
        self.gracefulExecutableURL = gracefulExecutableURL
        self.gracefulArguments = gracefulArguments
        self.forceExecutableURL = forceExecutableURL
        self.forceArguments = forceArguments
        self.monitorExecutableURL = monitorExecutableURL
        self.monitorArguments = monitorArguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.acceptedExitCodes = acceptedExitCodes
    }
}

public struct ProcessPlan: Sendable {
    public let sessionID: UUID
    public let applicationID: LibraryApplication.ID?
    public let environmentID: WindowsEnvironment.ID?
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectoryURL: URL?
    public let logURL: URL
    public let terminationPlan: ProcessTerminationPlan?

    public init(
        sessionID: UUID = UUID(),
        applicationID: LibraryApplication.ID? = nil,
        environmentID: WindowsEnvironment.ID? = nil,
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectoryURL: URL? = nil,
        logURL: URL,
        terminationPlan: ProcessTerminationPlan? = nil
    ) {
        self.sessionID = sessionID
        self.applicationID = applicationID
        self.environmentID = environmentID
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.logURL = logURL
        self.terminationPlan = terminationPlan
    }
}
