import Foundation

public struct RuntimePerformanceSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let applicationID: LibraryApplication.ID
    public let environmentID: WindowsEnvironment.ID
    public let capturedAt: Date
    public let launchLatency: TimeInterval?
    public let processCount: Int
    public let cpuPercent: Double
    public let residentMemoryBytes: UInt64
    public let graphicsBackend: GraphicsBackend
    public let engineBuildID: String?
    public let metalHUDEnabled: Bool

    public init(
        id: UUID = UUID(),
        applicationID: LibraryApplication.ID,
        environmentID: WindowsEnvironment.ID,
        capturedAt: Date = .now,
        launchLatency: TimeInterval? = nil,
        processCount: Int,
        cpuPercent: Double,
        residentMemoryBytes: UInt64,
        graphicsBackend: GraphicsBackend,
        engineBuildID: String?,
        metalHUDEnabled: Bool
    ) {
        self.id = id
        self.applicationID = applicationID
        self.environmentID = environmentID
        self.capturedAt = capturedAt
        self.launchLatency = launchLatency
        self.processCount = processCount
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
        self.graphicsBackend = graphicsBackend
        self.engineBuildID = engineBuildID
        self.metalHUDEnabled = metalHUDEnabled
    }
}
