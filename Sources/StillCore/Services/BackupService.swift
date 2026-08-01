import CryptoKit
import Foundation
import Security

private struct BackupFileEntry {
    let sourceURL: URL
    let relativePath: String
    let permissions: Int
    let byteCount: Int64
    let sha256: String
}

private struct BackupFileMetadata: Codable {
    let relativePath: String
    let permissions: Int
    let byteCount: Int64
    let sha256: String
}

private struct LegacyBackupFileRecord: Codable {
    let relativePath: String
    let permissions: Int
    let data: Data
}

private struct LegacyBackupPayload: Codable {
    let manifest: BackupManifest
    let files: [LegacyBackupFileRecord]
}

private struct LegacyBackupEnvelope: Codable {
    static let supportedVersion = 1
    let envelopeVersion: Int
    let isEncrypted: Bool
    let salt: Data?
    let payload: Data?
    let sealedPayload: Data?
}

private struct BackupKeyDerivation: Codable {
    static let current = BackupKeyDerivation(
        algorithm: "pbkdf2-hmac-sha256",
        version: 1,
        iterations: 210_000,
        keyByteCount: 32
    )

    let algorithm: String
    let version: Int
    let iterations: Int
    let keyByteCount: Int

    func validate() throws {
        guard algorithm == Self.current.algorithm,
              version == Self.current.version,
              (100_000 ... 2_000_000).contains(iterations),
              keyByteCount == 32 else {
            throw StillCoreError.invalidStore(
                "The backup uses unsupported password protection parameters."
            )
        }
    }
}

private struct BackupContainerHeader: Codable {
    static let contract = "app.stillproject.backup"
    static let currentVersion = 2

    let contractID: String
    let containerVersion: Int
    let isEncrypted: Bool
    let keyDerivation: BackupKeyDerivation?
    let salt: Data?
    let noncePrefix: Data?
}

private enum BackupFrameKind: UInt8 {
    case manifest = 1
    case fileMetadata = 2
    case fileChunk = 3
    case fileEnd = 4
    case archiveEnd = 255
}

private struct BackupFrame {
    let kind: BackupFrameKind
    let payload: Data
}

private enum BackupPasswordKeyDeriver {
    static func derive(
        password: String,
        salt: Data,
        parameters: BackupKeyDerivation
    ) throws -> SymmetricKey {
        try parameters.validate()
        guard !password.isEmpty, (16 ... 64).contains(salt.count) else {
            throw StillCoreError.backupDecryptionFailed
        }

        let passwordKey = SymmetricKey(data: Data(password.utf8))
        var blockInput = salt
        blockInput.append(contentsOf: [0, 0, 0, 1])
        var digest = Array(
            HMAC<SHA256>.authenticationCode(for: blockInput, using: passwordKey)
        )
        var result = digest
        if parameters.iterations > 1 {
            for _ in 1 ..< parameters.iterations {
                digest = Array(
                    HMAC<SHA256>.authenticationCode(
                        for: Data(digest),
                        using: passwordKey
                    )
                )
                for index in result.indices {
                    result[index] ^= digest[index]
                }
            }
        }
        return SymmetricKey(data: Data(result.prefix(parameters.keyByteCount)))
    }
}

private final class BackupContainerWriter {
    static let magic = Data("STILLBK2".utf8)
    static let chunkByteCount = 1_048_576

    private let handle: FileHandle
    private let headerDigest: Data
    private let key: SymmetricKey?
    private let noncePrefix: Data?
    private var frameIndex: UInt32 = 0

    init(
        url: URL,
        encrypted: Bool,
        password: String?,
        randomData: (Int) throws -> Data,
        encoder: JSONEncoder
    ) throws {
        let salt: Data?
        let noncePrefix: Data?
        let keyDerivation: BackupKeyDerivation?
        if encrypted {
            guard let password, !password.isEmpty else {
                throw StillCoreError.backupPasswordRequired
            }
            let generatedSalt = try randomData(16)
            let generatedNoncePrefix = try randomData(8)
            salt = generatedSalt
            noncePrefix = generatedNoncePrefix
            keyDerivation = .current
            key = try BackupPasswordKeyDeriver.derive(
                password: password,
                salt: generatedSalt,
                parameters: .current
            )
        } else {
            salt = nil
            noncePrefix = nil
            keyDerivation = nil
            key = nil
        }
        self.noncePrefix = noncePrefix

        let header = BackupContainerHeader(
            contractID: BackupContainerHeader.contract,
            containerVersion: BackupContainerHeader.currentVersion,
            isEncrypted: encrypted,
            keyDerivation: keyDerivation,
            salt: salt,
            noncePrefix: noncePrefix
        )
        let headerData = try encoder.encode(header)
        guard headerData.count <= 65_536 else {
            throw StillCoreError.invalidStore("The backup header is too large.")
        }
        headerDigest = Data(SHA256.hash(data: headerData))

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw StillCoreError.invalidStore("The backup file could not be created.")
        }
        handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: Self.magic)
            try handle.write(contentsOf: Self.integerData(UInt32(headerData.count)))
            try handle.write(contentsOf: headerData)
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    func write(kind: BackupFrameKind, payload: Data) throws {
        guard frameIndex < UInt32.max else {
            throw StillCoreError.invalidStore("The backup contains too many frames.")
        }
        let storedPayload: Data
        if let key, let noncePrefix {
            let nonce = try AES.GCM.Nonce(data: nonceData(prefix: noncePrefix))
            let sealed = try AES.GCM.seal(
                payload,
                using: key,
                nonce: nonce,
                authenticating: authenticatedData(kind: kind)
            )
            storedPayload = sealed.ciphertext + sealed.tag
        } else {
            storedPayload = payload
        }
        try handle.write(contentsOf: Data([kind.rawValue]))
        try handle.write(contentsOf: Self.integerData(UInt64(storedPayload.count)))
        try handle.write(contentsOf: storedPayload)
        frameIndex += 1
    }

    func finish() throws {
        try handle.synchronize()
        try handle.close()
    }

    private func nonceData(prefix: Data) -> Data {
        prefix + Self.integerData(frameIndex)
    }

    private func authenticatedData(kind: BackupFrameKind) -> Data {
        Self.magic + headerDigest + Self.integerData(frameIndex) + Data([kind.rawValue])
    }

    fileprivate static func integerData<T: FixedWidthInteger>(_ value: T) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}

private final class BackupContainerReader {
    private static let maximumManifestSize = 16 * 1_048_576
    private static let maximumMetadataSize = 65_536

    private let handle: FileHandle
    private var headerDigest = Data()
    private var key: SymmetricKey?
    private var noncePrefix: Data?
    private var frameIndex: UInt32 = 0

    init(url: URL, password: String?, decoder: JSONDecoder) throws {
        handle = try FileHandle(forReadingFrom: url)
        do {
            let magic = try readExactly(BackupContainerWriter.magic.count)
            guard magic == BackupContainerWriter.magic else {
                throw StillCoreError.invalidStore("The backup container is not recognized.")
            }
            let headerLength = Int(try readInteger(UInt32.self))
            guard (1 ... 65_536).contains(headerLength) else {
                throw StillCoreError.invalidStore("The backup header length is invalid.")
            }
            let headerData = try readExactly(headerLength)
            headerDigest = Data(SHA256.hash(data: headerData))
            let header = try decoder.decode(BackupContainerHeader.self, from: headerData)
            guard header.contractID == BackupContainerHeader.contract,
                  header.containerVersion == BackupContainerHeader.currentVersion else {
                throw StillCoreError.unsupportedSchema(header.containerVersion)
            }
            if header.isEncrypted {
                guard let password, !password.isEmpty else {
                    throw StillCoreError.backupPasswordRequired
                }
                guard let parameters = header.keyDerivation,
                      let salt = header.salt,
                      let noncePrefix = header.noncePrefix,
                      noncePrefix.count == 8 else {
                    throw StillCoreError.backupDecryptionFailed
                }
                self.noncePrefix = noncePrefix
                key = try BackupPasswordKeyDeriver.derive(
                    password: password,
                    salt: salt,
                    parameters: parameters
                )
            } else {
                guard header.keyDerivation == nil,
                      header.salt == nil,
                      header.noncePrefix == nil else {
                    throw StillCoreError.invalidStore(
                        "The unencrypted backup header is inconsistent."
                    )
                }
                noncePrefix = nil
                key = nil
            }
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    func readManifest(decoder: JSONDecoder) throws -> BackupManifest {
        let frame = try readFrame()
        guard frame.kind == .manifest else {
            throw StillCoreError.invalidStore("The backup manifest is missing.")
        }
        let manifest = try decoder.decode(BackupManifest.self, from: frame.payload)
        guard manifest.formatVersion == BackupManifest.currentFormatVersion else {
            throw StillCoreError.unsupportedSchema(manifest.formatVersion)
        }
        return manifest
    }

    func readFrame() throws -> BackupFrame {
        guard frameIndex < UInt32.max else {
            throw StillCoreError.invalidStore("The backup contains too many frames.")
        }
        let kindData = try readExactly(1)
        guard let rawKind = kindData.first,
              let kind = BackupFrameKind(rawValue: rawKind) else {
            throw StillCoreError.invalidStore("The backup contains an unknown frame.")
        }
        let storedLength = try readInteger(UInt64.self)
        let maximum = maximumStoredSize(for: kind)
        guard storedLength <= UInt64(maximum) else {
            throw StillCoreError.invalidStore("A backup frame is too large.")
        }
        let storedPayload = try readExactly(Int(storedLength))
        let payload: Data
        if let key, let noncePrefix {
            guard storedPayload.count >= 16 else {
                throw StillCoreError.backupDecryptionFailed
            }
            let ciphertext = storedPayload.dropLast(16)
            let tag = storedPayload.suffix(16)
            do {
                let nonce = try AES.GCM.Nonce(data: nonceData(prefix: noncePrefix))
                let box = try AES.GCM.SealedBox(
                    nonce: nonce,
                    ciphertext: ciphertext,
                    tag: tag
                )
                payload = try AES.GCM.open(
                    box,
                    using: key,
                    authenticating: authenticatedData(kind: kind)
                )
            } catch {
                throw StillCoreError.backupDecryptionFailed
            }
        } else {
            payload = storedPayload
        }
        try validatePayloadSize(payload.count, for: kind)
        frameIndex += 1
        return BackupFrame(kind: kind, payload: payload)
    }

    func requireEndOfFile() throws {
        let trailing = try handle.read(upToCount: 1) ?? Data()
        guard trailing.isEmpty else {
            throw StillCoreError.invalidStore("The backup has trailing data.")
        }
    }

    private func maximumStoredSize(for kind: BackupFrameKind) -> Int {
        let authenticationBytes = key == nil ? 0 : 16
        switch kind {
        case .manifest:
            return Self.maximumManifestSize + authenticationBytes
        case .fileMetadata:
            return Self.maximumMetadataSize + authenticationBytes
        case .fileChunk:
            return BackupContainerWriter.chunkByteCount + authenticationBytes
        case .fileEnd, .archiveEnd:
            return authenticationBytes
        }
    }

    private func validatePayloadSize(_ count: Int, for kind: BackupFrameKind) throws {
        let valid: Bool
        switch kind {
        case .manifest:
            valid = (1 ... Self.maximumManifestSize).contains(count)
        case .fileMetadata:
            valid = (1 ... Self.maximumMetadataSize).contains(count)
        case .fileChunk:
            valid = (1 ... BackupContainerWriter.chunkByteCount).contains(count)
        case .fileEnd, .archiveEnd:
            valid = count == 0
        }
        guard valid else {
            throw StillCoreError.invalidStore("A backup frame has an invalid size.")
        }
    }

    private func nonceData(prefix: Data) -> Data {
        prefix + BackupContainerWriter.integerData(frameIndex)
    }

    private func authenticatedData(kind: BackupFrameKind) -> Data {
        BackupContainerWriter.magic
            + headerDigest
            + BackupContainerWriter.integerData(frameIndex)
            + Data([kind.rawValue])
    }

    private func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let part = try handle.read(upToCount: count - result.count),
                  !part.isEmpty else {
                throw StillCoreError.invalidStore("The backup is truncated.")
            }
            result.append(part)
        }
        return result
    }

    private func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let data = try readExactly(MemoryLayout<T>.size)
        return data.reduce(T.zero) { ($0 << 8) | T($1) }
    }
}

public actor BackupService {
    typealias RandomDataSource = @Sendable (Int) throws -> Data

    private let fileManager: FileManager
    private let randomDataSource: RandomDataSource

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        randomDataSource = Self.secureRandomData
    }

    init(
        fileManager: FileManager = .default,
        randomDataSource: @escaping RandomDataSource
    ) {
        self.fileManager = fileManager
        self.randomDataSource = randomDataSource
    }

    public func preview(
        environment: WindowsEnvironment,
        applications: [LibraryApplication],
        launchEntries: [LaunchEntry],
        components: [RuntimeComponent],
        destinationURL: URL,
        encrypted: Bool
    ) throws -> BackupPreview {
        let entries = try fileEntries(at: environment.prefixURL)
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
                fileCount: entries.count,
                byteCount: entries.reduce(0) { $0 + $1.byteCount }
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
        let entries = try fileEntries(at: environment.prefixURL)
        guard entries.count == preview.manifest.fileCount,
              entries.reduce(0, { $0 + $1.byteCount }) == preview.manifest.byteCount else {
            throw StillCoreError.verificationFailed(
                "The Environment changed after the backup preview was created."
            )
        }

        try fileManager.createDirectory(
            at: preview.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = preview.destinationURL
            .deletingLastPathComponent()
            .appending(path: ".still-backup-\(UUID().uuidString).tmp")
        do {
            let writer = try BackupContainerWriter(
                url: temporaryURL,
                encrypted: preview.isEncrypted,
                password: password,
                randomData: randomDataSource,
                encoder: encoder
            )
            try writer.write(
                kind: .manifest,
                payload: encoder.encode(preview.manifest)
            )
            for entry in entries {
                let metadata = BackupFileMetadata(
                    relativePath: entry.relativePath,
                    permissions: entry.permissions,
                    byteCount: entry.byteCount,
                    sha256: entry.sha256
                )
                try writer.write(
                    kind: .fileMetadata,
                    payload: encoder.encode(metadata)
                )
                try writeFile(entry, to: writer)
                try writer.write(kind: .fileEnd, payload: Data())
            }
            try writer.write(kind: .archiveEnd, payload: Data())
            try writer.finish()
            try commitTemporaryBackup(
                temporaryURL,
                destinationURL: preview.destinationURL
            )
            return preview.manifest
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    public func inspectBackup(
        at backupURL: URL,
        password: String? = nil
    ) throws -> BackupManifest {
        if try isCurrentContainer(at: backupURL) {
            return try BackupContainerReader(
                url: backupURL,
                password: password,
                decoder: decoder
            ).readManifest(decoder: decoder)
        }
        return try decodeLegacyPayload(at: backupURL, password: password).manifest
    }

    @discardableResult
    public func restore(
        backupURL: URL,
        destinationPrefixURL: URL,
        password: String? = nil,
        activeSessions: [LaunchSession] = []
    ) throws -> BackupManifest {
        if try isCurrentContainer(at: backupURL) {
            return try restoreCurrentContainer(
                backupURL: backupURL,
                destinationPrefixURL: destinationPrefixURL,
                password: password,
                activeSessions: activeSessions
            )
        }
        return try restoreLegacyContainer(
            backupURL: backupURL,
            destinationPrefixURL: destinationPrefixURL,
            password: password,
            activeSessions: activeSessions
        )
    }

    private func writeFile(
        _ entry: BackupFileEntry,
        to writer: BackupContainerWriter
    ) throws {
        let handle = try FileHandle(forReadingFrom: entry.sourceURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try handle.read(
            upToCount: BackupContainerWriter.chunkByteCount
        ), !chunk.isEmpty {
            byteCount += Int64(chunk.count)
            hasher.update(data: chunk)
            try writer.write(kind: .fileChunk, payload: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard byteCount == entry.byteCount, digest == entry.sha256 else {
            throw StillCoreError.verificationFailed(
                "A source file changed while the backup was being created."
            )
        }
    }

    private func restoreCurrentContainer(
        backupURL: URL,
        destinationPrefixURL: URL,
        password: String?,
        activeSessions: [LaunchSession]
    ) throws -> BackupManifest {
        let reader = try BackupContainerReader(
            url: backupURL,
            password: password,
            decoder: decoder
        )
        let manifest = try reader.readManifest(decoder: decoder)
        try requireStopped(manifest.environment.id, sessions: activeSessions)
        try requireCleanRestoreDestination(destinationPrefixURL)
        let stagingURL = restoreStagingURL(for: destinationPrefixURL)
        var outputHandle: FileHandle?
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            var metadata: BackupFileMetadata?
            var hasher: SHA256?
            var restoredByteCount: Int64 = 0
            var totalByteCount: Int64 = 0
            var fileCount = 0
            var paths = Set<String>()

            while true {
                let frame = try reader.readFrame()
                switch frame.kind {
                case .manifest:
                    throw StillCoreError.invalidStore(
                        "The backup contains more than one manifest."
                    )
                case .fileMetadata:
                    guard metadata == nil else {
                        throw StillCoreError.invalidStore(
                            "A backup file record was not completed."
                        )
                    }
                    let value = try decoder.decode(
                        BackupFileMetadata.self,
                        from: frame.payload
                    )
                    try validate(metadata: value)
                    guard paths.insert(value.relativePath).inserted else {
                        throw StillCoreError.invalidStore(
                            "The backup contains duplicate file paths."
                        )
                    }
                    let outputURL = stagingURL.appending(path: value.relativePath)
                    try fileManager.createDirectory(
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
                        throw StillCoreError.invalidStore(
                            "A restored file could not be created."
                        )
                    }
                    outputHandle = try FileHandle(forWritingTo: outputURL)
                    metadata = value
                    hasher = SHA256()
                    restoredByteCount = 0
                case .fileChunk:
                    guard let current = metadata, var currentHasher = hasher,
                          let outputHandle else {
                        throw StillCoreError.invalidStore(
                            "The backup contains file data without metadata."
                        )
                    }
                    restoredByteCount += Int64(frame.payload.count)
                    guard restoredByteCount <= current.byteCount else {
                        throw StillCoreError.invalidStore(
                            "A restored file exceeds its recorded size."
                        )
                    }
                    currentHasher.update(data: frame.payload)
                    hasher = currentHasher
                    try outputHandle.write(contentsOf: frame.payload)
                case .fileEnd:
                    guard let current = metadata, let currentHasher = hasher,
                          let currentOutputHandle = outputHandle else {
                        throw StillCoreError.invalidStore(
                            "The backup contains an unexpected file boundary."
                        )
                    }
                    try currentOutputHandle.synchronize()
                    try currentOutputHandle.close()
                    outputHandle = nil
                    let digest = currentHasher.finalize()
                        .map { String(format: "%02x", $0) }.joined()
                    guard restoredByteCount == current.byteCount,
                          digest == current.sha256 else {
                        throw StillCoreError.verificationFailed(
                            "A restored file failed integrity verification."
                        )
                    }
                    let outputURL = stagingURL.appending(path: current.relativePath)
                    try fileManager.setAttributes(
                        [.posixPermissions: current.permissions],
                        ofItemAtPath: outputURL.path
                    )
                    totalByteCount += restoredByteCount
                    fileCount += 1
                    metadata = nil
                    hasher = nil
                case .archiveEnd:
                    guard metadata == nil else {
                        throw StillCoreError.invalidStore(
                            "The backup ended inside a file record."
                        )
                    }
                    try reader.requireEndOfFile()
                    guard fileCount == manifest.fileCount,
                          totalByteCount == manifest.byteCount else {
                        throw StillCoreError.verificationFailed(
                            "The restored file set does not match the manifest."
                        )
                    }
                    try fileManager.moveItem(at: stagingURL, to: destinationPrefixURL)
                    return manifest
                }
            }
        } catch {
            try? outputHandle?.close()
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    private func restoreLegacyContainer(
        backupURL: URL,
        destinationPrefixURL: URL,
        password: String?,
        activeSessions: [LaunchSession]
    ) throws -> BackupManifest {
        let payload = try decodeLegacyPayload(at: backupURL, password: password)
        try requireStopped(payload.manifest.environment.id, sessions: activeSessions)
        try requireCleanRestoreDestination(destinationPrefixURL)
        let stagingURL = restoreStagingURL(for: destinationPrefixURL)
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

    private func fileEntries(at rootURL: URL) throws -> [BackupFileEntry] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var entries: [BackupFileEntry] = []
        for case let url as URL in enumerator {
            let relative = try FileTreeServices.relativePath(of: url, under: rootURL)
            if shouldExclude(relative) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value
                ?? Int64(values.fileSize ?? 0)
            entries.append(BackupFileEntry(
                sourceURL: url,
                relativePath: relative,
                permissions: attributes[.posixPermissions] as? Int ?? 0o644,
                byteCount: byteCount,
                sha256: try SHA256Verifier.digest(of: url)
            ))
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
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

    private func decodeLegacyPayload(
        at backupURL: URL,
        password: String?
    ) throws -> LegacyBackupPayload {
        let envelope = try decoder.decode(
            LegacyBackupEnvelope.self,
            from: Data(contentsOf: backupURL)
        )
        guard envelope.envelopeVersion == LegacyBackupEnvelope.supportedVersion else {
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
                    using: legacyDerivedKey(password: password, salt: salt)
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
        let payload = try decoder.decode(LegacyBackupPayload.self, from: data)
        guard payload.manifest.formatVersion == 1,
              payload.files.count == payload.manifest.fileCount,
              payload.files.reduce(Int64(0), { $0 + Int64($1.data.count) })
                == payload.manifest.byteCount else {
            throw StillCoreError.verificationFailed(
                "The legacy backup contents do not match its manifest."
            )
        }
        var paths = Set<String>()
        for record in payload.files {
            try validate(relativePath: record.relativePath)
            guard paths.insert(record.relativePath).inserted,
                  (0 ... 0o7777).contains(record.permissions) else {
                throw StillCoreError.invalidStore(
                    "The legacy backup contains invalid file metadata."
                )
            }
        }
        return payload
    }

    private func isCurrentContainer(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: BackupContainerWriter.magic.count) ?? Data()
        return prefix == BackupContainerWriter.magic
    }

    private func validate(metadata: BackupFileMetadata) throws {
        try validate(relativePath: metadata.relativePath)
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard metadata.byteCount >= 0,
              (0 ... 0o7777).contains(metadata.permissions),
              metadata.sha256.count == 64,
              metadata.sha256.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            throw StillCoreError.invalidStore("Backup file metadata is invalid.")
        }
    }

    private func validate(relativePath: String) throws {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !relativePath.contains("\\") else {
            throw StillCoreError.unsafeArchivePath(relativePath)
        }
    }

    private func requireCleanRestoreDestination(_ destinationURL: URL) throws {
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw StillCoreError.invalidStore(
                "Restore destination already exists. Restore into a clean location or create a Restore Point first."
            )
        }
    }

    private func restoreStagingURL(for destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent()
            .appending(path: ".still-restore-\(UUID().uuidString)")
    }

    private func commitTemporaryBackup(
        _ temporaryURL: URL,
        destinationURL: URL
    ) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private func requireStopped(_ environmentID: UUID, sessions: [LaunchSession]) throws {
        if sessions.contains(where: {
            $0.environmentID == environmentID && $0.state.isActive
        }) {
            throw StillCoreError.environmentMustBeStopped(environmentID)
        }
    }

    private func legacyDerivedKey(password: String, salt: Data) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: salt + Data(password.utf8)))
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw StillCoreError.verificationFailed(
                "Secure random data could not be generated."
            )
        }
        return Data(bytes)
    }

    private var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys]
        return value
    }

    private var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}
