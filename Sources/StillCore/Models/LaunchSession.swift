import Foundation

public enum LaunchSessionState: String, Codable, Sendable {
    case preparing
    case launching
    case running
    case stopping
    case exited
    case failed

    public var isActive: Bool {
        switch self {
        case .preparing, .launching, .running, .stopping: true
        case .exited, .failed: false
        }
    }

    fileprivate func canTransition(to next: Self) -> Bool {
        switch (self, next) {
        case (.preparing, .launching), (.preparing, .failed),
             (.launching, .running), (.launching, .stopping),
             (.launching, .failed),
             (.running, .stopping), (.running, .exited), (.running, .failed),
             (.stopping, .exited), (.stopping, .failed):
            true
        default:
            false
        }
    }
}

public struct AttributedProcess: Codable, Hashable, Identifiable, Sendable {
    public var id: Int32 { processIdentifier }
    public let processIdentifier: Int32
    public let name: String
    public let applicationID: LibraryApplication.ID?
    public let environmentID: WindowsEnvironment.ID?
    public let launchSessionID: UUID
    public let isRootProcess: Bool
    public let processStartedAt: Date?

    public init(
        processIdentifier: Int32,
        name: String,
        applicationID: LibraryApplication.ID?,
        environmentID: WindowsEnvironment.ID?,
        launchSessionID: UUID,
        isRootProcess: Bool = false,
        processStartedAt: Date? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.name = name
        self.applicationID = applicationID
        self.environmentID = environmentID
        self.launchSessionID = launchSessionID
        self.isRootProcess = isRootProcess
        self.processStartedAt = processStartedAt
    }
}

public struct LaunchSession: Codable, Hashable, Identifiable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public let applicationID: LibraryApplication.ID?
    public let environmentID: WindowsEnvironment.ID?
    public private(set) var state: LaunchSessionState
    public private(set) var rootProcessIdentifier: Int32?
    public private(set) var rootProcessStartedAt: Date?
    public private(set) var attributedProcesses: [AttributedProcess]
    public let createdAt: Date
    public private(set) var startedAt: Date
    public private(set) var finishedAt: Date?
    public private(set) var exitCode: Int32?
    public private(set) var failureDescription: String?
    public let logURL: URL?

    public var processIdentifier: Int32 { rootProcessIdentifier ?? 0 }

    public init(
        id: ID = UUID(),
        applicationID: LibraryApplication.ID? = nil,
        environmentID: WindowsEnvironment.ID? = nil,
        state: LaunchSessionState = .preparing,
        createdAt: Date = .now,
        logURL: URL? = nil
    ) {
        self.id = id
        self.applicationID = applicationID
        self.environmentID = environmentID
        self.state = state
        self.rootProcessIdentifier = nil
        self.rootProcessStartedAt = nil
        self.attributedProcesses = []
        self.createdAt = createdAt
        self.startedAt = createdAt
        self.finishedAt = nil
        self.exitCode = nil
        self.failureDescription = nil
        self.logURL = logURL
    }

    // Compatibility initializer for callers that already launched a process.
    public init(
        id: ID = UUID(),
        processIdentifier: Int32,
        startedAt: Date = .now,
        logURL: URL? = nil
    ) {
        self.init(
            id: id,
            state: processIdentifier == 0 ? .preparing : .running,
            createdAt: startedAt,
            logURL: logURL
        )
        self.rootProcessIdentifier = processIdentifier == 0 ? nil : processIdentifier
    }

    public mutating func transition(
        to next: LaunchSessionState,
        at date: Date = .now,
        rootProcessIdentifier: Int32? = nil,
        rootProcessStartedAt: Date? = nil,
        exitCode: Int32? = nil,
        failureDescription: String? = nil
    ) throws {
        guard state.canTransition(to: next) else {
            throw StillCoreError.invalidApplicationState("\(state.rawValue) -> \(next.rawValue)")
        }
        state = next
        if next == .running {
            startedAt = date
            self.rootProcessIdentifier = rootProcessIdentifier
            self.rootProcessStartedAt = rootProcessStartedAt
        }
        if !next.isActive {
            finishedAt = date
            self.exitCode = exitCode
            self.failureDescription = failureDescription
        }
    }

    public mutating func replaceAttributedProcesses(_ processes: [AttributedProcess]) {
        attributedProcesses = processes.filter { $0.launchSessionID == id }
    }
}
