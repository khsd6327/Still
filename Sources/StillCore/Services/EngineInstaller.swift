import Foundation

public actor EngineInstaller {
    private let rootURL: URL
    private let fileManager: FileManager
    private let archiveExtractor: TarXZArchiveExtractor
    private let urlSession: URLSession

    public init(
        rootURL: URL = EngineLocations.defaultRootURL(),
        fileManager: FileManager = .default,
        archiveExtractor: TarXZArchiveExtractor = TarXZArchiveExtractor(),
        urlSession: URLSession = .shared
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.archiveExtractor = archiveExtractor
        self.urlSession = urlSession
    }

    public func install(
        _ manifest: EngineManifest,
        acceptsExternalLicense: Bool = false
    ) async throws -> EngineDescriptor {
        if manifest.distributionPolicy == .externalLicenseRequired,
           !acceptsExternalLicense {
            throw StillCoreError.externalLicenseAcceptanceRequired(manifest.id)
        }

        if let installed = installedDescriptor(for: manifest) {
            return installed
        }

        let (downloadedURL, response) = try await urlSession.download(
            from: manifest.downloadURL
        )
        if let httpResponse = response as? HTTPURLResponse,
           !(200 ... 299).contains(httpResponse.statusCode) {
            throw StillCoreError.engineDownloadFailed(httpResponse.statusCode)
        }

        return try installDownloadedArchive(
            manifest,
            archiveURL: downloadedURL,
            acceptsExternalLicense: acceptsExternalLicense
        )
    }

    public func installDownloadedArchive(
        _ manifest: EngineManifest,
        archiveURL: URL,
        acceptsExternalLicense: Bool = false
    ) throws -> EngineDescriptor {
        if manifest.distributionPolicy == .externalLicenseRequired,
           !acceptsExternalLicense {
            throw StillCoreError.externalLicenseAcceptanceRequired(manifest.id)
        }

        try SHA256Verifier.verify(
            fileURL: archiveURL,
            expectedDigest: manifest.sha256
        )

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let destinationURL = installationURL(for: manifest)
        if let installed = installedDescriptor(for: manifest) {
            return installed
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw StillCoreError.invalidEngineInstallation(destinationURL)
        }

        let stagingURL = rootURL.appending(
            path: ".installing-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        try archiveExtractor.extract(
            archiveURL: archiveURL,
            destinationURL: stagingURL
        )

        let stagedBinaryURL = binaryURL(
            for: manifest,
            installationURL: stagingURL
        )
        guard fileManager.isExecutableFile(atPath: stagedBinaryURL.path) else {
            throw StillCoreError.engineBinaryUnavailable(stagedBinaryURL)
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: stagingURL, to: destinationURL)

        guard let descriptor = installedDescriptor(for: manifest) else {
            throw StillCoreError.invalidEngineInstallation(destinationURL)
        }
        return descriptor
    }

    public func installedDescriptor(
        for manifest: EngineManifest
    ) -> EngineDescriptor? {
        let installationURL = installationURL(for: manifest)
        let wineBinaryURL = binaryURL(
            for: manifest,
            installationURL: installationURL
        )
        guard fileManager.isExecutableFile(atPath: wineBinaryURL.path) else {
            return nil
        }
        return EngineDescriptor(
            id: manifest.id,
            displayName: manifest.displayName,
            version: manifest.version,
            family: manifest.family,
            wineBinaryURL: wineBinaryURL,
            capabilities: manifest.capabilities,
            sourceArchiveSHA256: manifest.sha256
        )
    }

    public func installedDescriptors() -> [EngineDescriptor] {
        let bundled = BundledEngineCatalog.manifests.compactMap(installedDescriptor)
        let bundledIDs = Set(bundled.map(\.id))
        return (bundled + installedLocalDescriptors().filter {
            !bundledIDs.contains($0.id)
        }).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func installedLocalDescriptors() -> [EngineDescriptor] {
        guard let engineDirectories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return engineDirectories.flatMap { engineDirectory -> [EngineDescriptor] in
            guard isPlainDirectory(engineDirectory),
                  let versionDirectories = try? fileManager.contentsOfDirectory(
                    at: engineDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  ) else { return [] }
            return versionDirectories.compactMap { versionDirectory in
                localDescriptor(
                    engineDirectory: engineDirectory,
                    versionDirectory: versionDirectory
                )
            }
        }
    }

    private func localDescriptor(
        engineDirectory: URL,
        versionDirectory: URL
    ) -> EngineDescriptor? {
        guard isPlainDirectory(versionDirectory) else { return nil }
        let manifestURL = versionDirectory.appending(
            path: InstalledEngineBuildManifest.fileName
        )
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(
                InstalledEngineBuildManifest.self,
                from: data
              ),
              manifest.contractID == InstalledEngineBuildManifest.contract,
              manifest.schemaVersion == InstalledEngineBuildManifest.supportedSchemaVersion,
              manifest.id == engineDirectory.lastPathComponent,
              manifest.version == versionDirectory.lastPathComponent,
              isSafePathComponent(manifest.archiveRoot),
              isSafeRelativePath(manifest.wineBinaryRelativePath) else {
            return nil
        }
        let binaryURL = versionDirectory
            .appending(path: manifest.archiveRoot, directoryHint: .isDirectory)
            .appending(path: manifest.wineBinaryRelativePath)
        guard fileManager.isExecutableFile(atPath: binaryURL.path),
              validateArtifacts(
                manifest.artifacts,
                versionDirectory: versionDirectory,
                wineBinaryRelativePath: "\(manifest.archiveRoot)/\(manifest.wineBinaryRelativePath)"
              ) else { return nil }
        let descriptor = EngineDescriptor(
            id: manifest.id,
            displayName: manifest.displayName,
            version: manifest.version,
            family: manifest.family,
            wineBinaryURL: binaryURL,
            capabilities: manifest.capabilities,
            artifactManifestSHA256: manifest.artifacts.isEmpty
                ? nil
                : try? SHA256Verifier.digest(of: manifestURL)
        )
        if descriptor.capabilities.contains(.dxmt),
           !DXMTBridgeValidator().validate(engine: descriptor).isAvailable {
            return nil
        }
        return descriptor
    }

    private func validateArtifacts(
        _ artifacts: [InstalledEngineArtifact],
        versionDirectory: URL,
        wineBinaryRelativePath: String
    ) -> Bool {
        guard !artifacts.isEmpty else { return true }
        guard Set(artifacts.map(\.relativePath)).count == artifacts.count,
              artifacts.contains(where: {
                  $0.relativePath == wineBinaryRelativePath && $0.isExecutable
              }) else { return false }

        let rootPath = versionDirectory.standardizedFileURL.path
        for artifact in artifacts {
            guard isSafeRelativePath(artifact.relativePath),
                  artifact.sha256.count == 64,
                  artifact.byteCount >= 0 else { return false }
            let url = versionDirectory.appending(path: artifact.relativePath)
            let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedPath.hasPrefix(rootPath + "/"),
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == artifact.byteCount,
                  fileManager.isExecutableFile(atPath: url.path) == artifact.isExecutable,
                  (try? SHA256Verifier.verify(
                    fileURL: url,
                    expectedDigest: artifact.sha256
                  )) != nil else { return false }
        }
        return true
    }

    private func isPlainDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isSafePathComponent(_ path: String) -> Bool {
        !path.isEmpty && path != "." && path != ".." && !path.contains("/")
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.split(separator: "/").contains("..")
    }

    private func installationURL(for manifest: EngineManifest) -> URL {
        rootURL
            .appending(path: manifest.id, directoryHint: .isDirectory)
            .appending(path: manifest.version, directoryHint: .isDirectory)
    }

    private func binaryURL(
        for manifest: EngineManifest,
        installationURL: URL
    ) -> URL {
        installationURL
            .appending(path: manifest.archiveRoot, directoryHint: .isDirectory)
            .appending(path: manifest.wineBinaryRelativePath)
    }
}
