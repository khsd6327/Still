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
            wineBinaryURL: wineBinaryURL,
            capabilities: manifest.capabilities
        )
    }

    public func installedDescriptors() -> [EngineDescriptor] {
        BundledEngineCatalog.manifests.compactMap(installedDescriptor)
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
