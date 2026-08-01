import Foundation

public struct DiscoveryConfidence: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: Double

    public init(rawValue: Double) {
        self.rawValue = min(max(rawValue, 0), 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static let certain = Self(rawValue: 1)
    public static let high = Self(rawValue: 0.85)
    public static let medium = Self(rawValue: 0.65)
    public static let low = Self(rawValue: 0.4)
}

public struct DiscoveredApplicationCandidate: Hashable, Identifiable, Sendable {
    public var id: String { "\(providerID):\(application.id)" }
    public let providerID: String
    public let application: InstalledWindowsApplication
    public let category: LibraryApplicationCategory
    public let confidence: DiscoveryConfidence
    public let requiresConfirmation: Bool
    public let providerManagedState: WindowsApplicationInstallState?

    public init(
        providerID: String,
        application: InstalledWindowsApplication,
        category: LibraryApplicationCategory,
        confidence: DiscoveryConfidence,
        requiresConfirmation: Bool,
        providerManagedState: WindowsApplicationInstallState? = nil
    ) {
        self.providerID = providerID
        self.application = application
        self.category = category
        self.confidence = confidence
        self.requiresConfirmation = requiresConfirmation
        self.providerManagedState = providerManagedState
    }
}

public struct DiscoveryResult: Sendable {
    public let accepted: [DiscoveredApplicationCandidate]
    public let requiresConfirmation: [DiscoveredApplicationCandidate]
    public let providerFailures: [String: String]
}

public protocol ApplicationDiscoveryProvider {
    var id: String { get }
    func discover(in bottle: Bottle) throws -> [DiscoveredApplicationCandidate]
}
