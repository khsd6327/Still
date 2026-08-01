import Foundation

public struct ManagedEnvironmentMarker: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let environmentID: WindowsEnvironment.ID
    public let storeIdentifier: UUID
    public let nonce: UUID

    public init(
        version: Int = Self.currentVersion,
        environmentID: WindowsEnvironment.ID,
        storeIdentifier: UUID,
        nonce: UUID
    ) {
        self.version = version
        self.environmentID = environmentID
        self.storeIdentifier = storeIdentifier
        self.nonce = nonce
    }
}

public struct EnvironmentOwnershipService {
    public static let markerFilename = ".still-environment.json"

    public let managedRootURL: URL
    private let fileManager: FileManager

    public init(
        managedRootURL: URL = JSONStillStore.defaultRootURL().appending(
            path: "Environments",
            directoryHint: .isDirectory
        ),
        fileManager: FileManager = .default
    ) {
        self.managedRootURL = managedRootURL
        self.fileManager = fileManager
    }

    public func managedPrefixURL(for environmentID: WindowsEnvironment.ID) -> URL {
        managedRootURL.appending(
            path: environmentID.uuidString,
            directoryHint: .isDirectory
        )
    }

    @discardableResult
    public func writeMarker(
        for environment: WindowsEnvironment,
        storeIdentifier: UUID
    ) throws -> ManagedEnvironmentMarker {
        guard environment.ownership == .managed,
              let nonce = environment.managementNonce,
              hasExpectedManagedPath(environment) else {
            throw StillCoreError.invalidStore(
                "Environment '\(environment.id)' does not have verified managed ownership."
            )
        }
        try prepareManagedDirectory(environment.prefixURL)
        let marker = ManagedEnvironmentMarker(
            environmentID: environment.id,
            storeIdentifier: storeIdentifier,
            nonce: nonce
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(
            to: markerURL(for: environment.prefixURL),
            options: .atomic
        )
        return marker
    }

    public func validateManagedOwnership(
        of environment: WindowsEnvironment,
        storeIdentifier: UUID
    ) throws {
        guard environment.ownership == .managed,
              let nonce = environment.managementNonce,
              hasExpectedManagedPath(environment) else {
            throw StillCoreError.invalidStore(
                "Environment '\(environment.id)' is not a verified managed Environment."
            )
        }
        try requireRealDirectory(environment.prefixURL)
        let markerURL = markerURL(for: environment.prefixURL)
        let values = try markerURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw StillCoreError.invalidStore("The Environment ownership marker is a symbolic link.")
        }
        let marker = try JSONDecoder().decode(
            ManagedEnvironmentMarker.self,
            from: Data(contentsOf: markerURL)
        )
        guard marker.version == ManagedEnvironmentMarker.currentVersion,
              marker.environmentID == environment.id,
              marker.storeIdentifier == storeIdentifier,
              marker.nonce == nonce else {
            throw StillCoreError.invalidStore(
                "The Environment ownership marker does not match the store record."
            )
        }
    }

    private func hasExpectedManagedPath(_ environment: WindowsEnvironment) -> Bool {
        let expected = managedPrefixURL(for: environment.id).standardizedFileURL
        let actual = environment.prefixURL.standardizedFileURL
        guard expected.path == actual.path else { return false }
        return expected.resolvingSymlinksInPath().path
            == actual.resolvingSymlinksInPath().path
    }

    private func prepareManagedDirectory(_ prefixURL: URL) throws {
        if fileManager.fileExists(atPath: prefixURL.path) {
            try requireRealDirectory(prefixURL)
            return
        }
        try fileManager.createDirectory(at: prefixURL, withIntermediateDirectories: true)
        try requireRealDirectory(prefixURL)
    }

    private func requireRealDirectory(_ prefixURL: URL) throws {
        let values = try prefixURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw StillCoreError.invalidStore(
                "The managed Environment path must be a real directory."
            )
        }
    }

    private func markerURL(for prefixURL: URL) -> URL {
        prefixURL.appending(path: Self.markerFilename)
    }
}
