import Darwin
import Foundation

public struct ManagedEnvironmentFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct ManagedEnvironmentMarker: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public let version: Int
    public let environmentID: WindowsEnvironment.ID
    public let storeIdentifier: UUID
    public let nonce: UUID
    public let fileIdentity: ManagedEnvironmentFileIdentity?

    public init(
        version: Int = Self.currentVersion,
        environmentID: WindowsEnvironment.ID,
        storeIdentifier: UUID,
        nonce: UUID,
        fileIdentity: ManagedEnvironmentFileIdentity? = nil
    ) {
        self.version = version
        self.environmentID = environmentID
        self.storeIdentifier = storeIdentifier
        self.nonce = nonce
        self.fileIdentity = fileIdentity
    }
}

public struct EnvironmentOwnershipService: @unchecked Sendable {
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
            nonce: nonce,
            fileIdentity: try fileIdentity(at: environment.prefixURL)
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
        try validateManagedMarker(
            at: environment.prefixURL,
            environmentID: environment.id,
            storeIdentifier: storeIdentifier,
            nonce: nonce
        )
    }

    public func validateManagedMarker(
        at prefixURL: URL,
        environmentID: WindowsEnvironment.ID,
        storeIdentifier: UUID,
        nonce: UUID
    ) throws {
        try requireRealDirectory(prefixURL)
        let markerURL = markerURL(for: prefixURL)
        let values = try markerURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw StillCoreError.invalidStore("The Environment ownership marker is a symbolic link.")
        }
        let marker = try JSONDecoder().decode(
            ManagedEnvironmentMarker.self,
            from: Data(contentsOf: markerURL)
        )
        guard (1 ... ManagedEnvironmentMarker.currentVersion).contains(marker.version),
              marker.environmentID == environmentID,
              marker.storeIdentifier == storeIdentifier,
              marker.nonce == nonce else {
            throw StillCoreError.invalidStore(
                "The Environment ownership marker does not match the store record."
            )
        }
        let currentIdentity = try fileIdentity(at: prefixURL)
        if let recordedIdentity = marker.fileIdentity {
            guard recordedIdentity == currentIdentity else {
                throw StillCoreError.invalidStore(
                    "The Environment directory identity does not match its ownership marker."
                )
            }
        } else {
            let upgraded = ManagedEnvironmentMarker(
                environmentID: environmentID,
                storeIdentifier: storeIdentifier,
                nonce: nonce,
                fileIdentity: currentIdentity
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(upgraded).write(to: markerURL, options: .atomic)
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

    private func fileIdentity(at url: URL) throws -> ManagedEnvironmentFileIdentity {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw StillCoreError.invalidStore("A managed path is invalid.") }
            var status = stat()
            guard lstat(path, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard (status.st_mode & S_IFMT) == S_IFDIR else {
                throw StillCoreError.invalidStore(
                    "The managed Environment path is not a directory."
                )
            }
            return ManagedEnvironmentFileIdentity(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            )
        }
    }
}
