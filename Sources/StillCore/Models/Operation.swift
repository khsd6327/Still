import Foundation

public enum OperationKind: String, Codable, CaseIterable, Sendable {
    case createEnvironment
    case importEnvironment
    case launchInstaller
    case installApplication
    case installComponent
    case repair
    case duplicateEnvironment
    case createRestorePoint
    case backup
    case restore
    case deleteEnvironment

    public var mutatesEnvironment: Bool { true }
}

public enum OperationState: String, Codable, Sendable {
    case pending
    case running
    case cancelling
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        default: false
        }
    }

    fileprivate func canTransition(to next: Self) -> Bool {
        switch (self, next) {
        case (.pending, .running), (.pending, .cancelled),
             (.running, .cancelling), (.running, .succeeded),
             (.running, .failed), (.cancelling, .cancelled),
             (.cancelling, .failed):
            true
        default:
            false
        }
    }
}

public struct OperationEvent: Codable, Hashable, Sendable {
    public let occurredAt: Date
    public let message: String

    public init(occurredAt: Date = .now, message: String) {
        self.occurredAt = occurredAt
        self.message = message
    }
}

public struct StillOperation: Codable, Hashable, Identifiable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public let kind: OperationKind
    public let environmentID: WindowsEnvironment.ID
    public let applicationID: LibraryApplication.ID?
    public private(set) var state: OperationState
    public private(set) var progress: Double?
    public let createdAt: Date
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    public private(set) var resultSummary: String?
    public private(set) var events: [OperationEvent]

    public init(
        id: ID = UUID(),
        kind: OperationKind,
        environmentID: WindowsEnvironment.ID,
        applicationID: LibraryApplication.ID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.environmentID = environmentID
        self.applicationID = applicationID
        self.state = .pending
        self.progress = nil
        self.createdAt = createdAt
        self.startedAt = nil
        self.finishedAt = nil
        self.resultSummary = nil
        self.events = []
    }

    public mutating func transition(
        to next: OperationState,
        at date: Date = .now,
        resultSummary: String? = nil
    ) throws {
        guard state.canTransition(to: next) else {
            throw StillCoreError.invalidOperationTransition(
                from: state.rawValue,
                to: next.rawValue
            )
        }
        state = next
        if next == .running { startedAt = date }
        if next.isTerminal { finishedAt = date }
        if let resultSummary { self.resultSummary = resultSummary }
    }

    public mutating func updateProgress(_ value: Double?) {
        progress = value.map { min(max($0, 0), 1) }
    }

    public mutating func appendEvent(_ message: String, at date: Date = .now) {
        events.append(OperationEvent(occurredAt: date, message: message))
    }
}
