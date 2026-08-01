import Foundation

public struct LaunchRequest: Hashable, Sendable {
    public let bottle: Bottle
    public let executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectoryURL: URL?
    public var applicationID: LibraryApplication.ID?
    public var environmentID: WindowsEnvironment.ID?

    public init(
        bottle: Bottle,
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectoryURL: URL? = nil,
        applicationID: LibraryApplication.ID? = nil,
        environmentID: WindowsEnvironment.ID? = nil
    ) {
        self.bottle = bottle
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.applicationID = applicationID
        self.environmentID = environmentID
    }
}
