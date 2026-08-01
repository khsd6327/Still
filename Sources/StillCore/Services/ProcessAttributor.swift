import Foundation

public struct ProcessAttributor: Sendable {
    public init() {}

    public func attribute(
        _ processes: [WindowsProcess],
        to session: LaunchSession
    ) -> [AttributedProcess] {
        processes.map {
            AttributedProcess(
                processIdentifier: $0.processID,
                name: $0.name,
                applicationID: session.applicationID,
                environmentID: session.environmentID,
                launchSessionID: session.id,
                isRootProcess: $0.processID == session.rootProcessIdentifier
            )
        }
    }
}
