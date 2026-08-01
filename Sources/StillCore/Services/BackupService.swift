import CryptoKit
import Foundation
import Security

private struct BackupFileRecord: Codable {
    let relativePath: String
    let permissions: Int
    let data: Data
}

private struct BackupPayload: Codable {
    let manifest: BackupManifest
    let files: [BackupFileRecord]
}

private struct BackupEnvelope: Codable {
    static let currentVersion = 1
    let envelopeVersion: Int
    let isEncrypted: Bool
    let salt: Data?
    let payload: Data?
    let sealedPayload: Data?
}

public actor BackupService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func preview(
        environment: WindowsEnvironment,
        applications: [LibraryApplication],
        launchEntries: [LaunchEntry],
        components: [RuntimeComponent],
        destinationURL: URL,
        encrypted: Bool
    ) throws -> BackupPreview {
        let records = try fileRecords(at: environment.prefixURL)
        let snapshot = ConfigurationSnapshot(
            environment: environment,
            applications: applications,
            launchEntries: launchEntries
        )
        return BackupPreview(
            manifest: BackupManifest(
                formatVersion: BackupManifest.currentFormatVersion,
                createdAt: .now,
                environment: environment,
                snapshot: snapshot,
                requiredEngineBuildID: environment.pinnedEngineBuildID,
                requiredComponents: Dictionary(
                    uniqueKeysWithValues: components.map { ($0.id, $0.version) }
                ),
                excludedCategories: [
                    "Engine and component binaries",
                    "External libraries",
                    "Browser cookies and account tokens",
                    "Windows user documents"
                ],
                fileCount: records.count,
                byteCount: Int64(records.reduce(0) { $0 + $1.data.count })
            ),
            destinationURL: destinationURL,
            isEncrypted: encrypted
        )
    }

    @discardableResult
    public func create(
        preview: BackupPreview,
        password: String? = nil,
        activeSessions: [LaunchSession]
    ) throws -> BackupManifest {
        let environment = preview.manifest.environment
        try requireStopped(environment.id, sessions: activeSessions)
        let records = try fileRecords(at: environment.prefixURL)
        let payload = BackupPayload(manifest: preview.manifest, files: records)
        let payloadData = try encoder.encode(payload)
        let envelope: BackupEnvelope
        if preview.isEncrypted {
            guard let password, !password.isEmpty else {
                throw StillCoreError.backupPasswordRequired
            }
            let salt = randomData(count: 16)
            let key = derivedKey(password: password, salt: salt)
            let sealed = try AES.GCM.seal(payloadData, using: key)
            envelope = BackupEnvelope(
                envelopeVersion: BackupEnvelope.currentVersion,
                isEncrypted: true,
                salt: salt,
                payload: nil,
                sealedPayload: sealed.combined
            )
        } else {
            envelope = BackupEnvelope(
                envelopeVersion: BackupEnvelope.currentVersion,
                isEncrypted: false,
                salt: nil,
                payload: payloadData,
                sealedPayload: nil
            )
        }
        try fileManager.createDirectory(
            at: preview.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(envelope).write(to: preview.destinationURL, options: .atomic)
        return preview.manifest
    }

    public func inspectBackup(
        at backupURL: URL,
        password: String? = nil
    ) throws -> BackupManifest {
        try decodePayload(at: backupURL, password: password).manifest
    }

    @discardableResult
    public func restore(
        backupURL: URL,
        destinationPrefixURL: URL,
        password: String? = nil,
        activeSessions: [LaunchSession] = []
    ) throws -> BackupManifest {
        let payload = try decodePayload(at: backupURL, password: password)
        try requireStopped(payload.manifest.environment.id, sessions: activeSessions)
        guard !fileManager.fileExists(atPath: destinationPrefixURL.path) else {
            throw StillCoreError.invalidStore(
                "Restore destination already exists. Restore into a clean location or create a Restore Point first."
            )
        }
        let stagingURL = destinationPrefixURL
            .deletingLastPathComponent()
            .appending(path: ".still-restore-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            for record in payload.files {
                try validate(relativePath: record.relativePath)
                let outputURL = stagingURL.appending(path: record.relativePath)
                try fileManager.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try record.data.write(to: outputURL, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: record.permissions],
                    ofItemAtPath: outputURL.path
                )
            }
            try fileManager.moveItem(at: stagingURL, to: destinationPrefixURL)
            return payload.manifest
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    private func fileRecords(at rootURL: URL) throws -> [BackupFileRecord] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var records: [BackupFileRecord] = []
        for case let url as URL in enumerator {
            let relative = try FileTreeServices.relativePath(of: url, under: rootURL)
            if shouldExclude(relative) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            records.append(BackupFileRecord(
                relativePath: relative,
                permissions: attributes[.posixPermissions] as? Int ?? 0o644,
                data: try Data(contentsOf: url)
            ))
        }
        return records.sorted { $0.relativePath < $1.relativePath }
    }

    private func shouldExclude(_ relativePath: String) -> Bool {
        let path = relativePath.lowercased().replacingOccurrences(of: "\\", with: "/")
        let sensitiveNames = ["cookies", "login data", "token", "credentials", "webcache"]
        if sensitiveNames.contains(where: path.contains) { return true }
        if path.contains("/users/") && (
            path.contains("/documents/")
                || path.contains("/downloads/")
                || path.contains("/desktop/")
        ) { return true }
        return path.contains("/cache/") || path.hasSuffix("/cache")
    }

    private func decodePayload(at backupURL: URL, password: String?) throws -> BackupPayload {
        let envelope = try decoder.decode(
            BackupEnvelope.self,
            from: Data(contentsOf: backupURL)
        )
        guard envelope.envelopeVersion == BackupEnvelope.currentVersion else {
            throw StillCoreError.unsupportedSchema(envelope.envelopeVersion)
        }
        let data: Data
        if envelope.isEncrypted {
            guard let password, !password.isEmpty else {
                throw StillCoreError.backupPasswordRequired
            }
            guard let salt = envelope.salt, let combined = envelope.sealedPayload else {
                throw StillCoreError.backupDecryptionFailed
            }
            do {
                data = try AES.GCM.open(
                    AES.GCM.SealedBox(combined: combined),
                    using: derivedKey(password: password, salt: salt)
                )
            } catch {
                throw StillCoreError.backupDecryptionFailed
            }
        } else {
            guard let payload = envelope.payload else {
                throw StillCoreError.invalidStore("Backup payload is missing.")
            }
            data = payload
        }
        return try decoder.decode(BackupPayload.self, from: data)
    }

    private func validate(relativePath: String) throws {
        let components = relativePath.split(separator: "/")
        guard !relativePath.hasPrefix("/"),
              !components.contains(".."),
              !relativePath.contains("\\") else {
            throw StillCoreError.unsafeArchivePath(relativePath)
        }
    }

    private func requireStopped(_ environmentID: UUID, sessions: [LaunchSession]) throws {
        if sessions.contains(where: {
            $0.environmentID == environmentID && $0.state.isActive
        }) {
            throw StillCoreError.environmentMustBeStopped(environmentID)
        }
    }

    private func derivedKey(password: String, salt: Data) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: salt + Data(password.utf8)))
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }

    private var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}
