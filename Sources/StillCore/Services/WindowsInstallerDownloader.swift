import Foundation

public struct DownloadedWindowsInstaller: Hashable, Sendable {
    public let fileURL: URL
    public let sha256: String

    public init(fileURL: URL, sha256: String) {
        self.fileURL = fileURL
        self.sha256 = sha256
    }
}

public actor WindowsInstallerDownloader {
    private let rootURL: URL
    private let fileManager: FileManager
    private let urlSession: URLSession

    public init(
        rootURL: URL = WindowsInstallerDownloader.defaultRootURL(),
        fileManager: FileManager = .default,
        urlSession: URLSession = .shared
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.urlSession = urlSession
    }

    public static func defaultRootURL(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appending(path: ProductIdentity.bundleIdentifier, directoryHint: .isDirectory)
        .appending(path: "Installers", directoryHint: .isDirectory)
    }

    public func download(
        recipeID: String,
        artifact: WindowsInstallerArtifact
    ) async throws -> DownloadedWindowsInstaller {
        guard artifact.downloadURL.scheme == "https",
              let host = artifact.downloadURL.host?.lowercased(),
              artifact.allowedHosts.contains(host) else {
            throw StillCoreError.untrustedInstallerURL(artifact.downloadURL)
        }

        let (temporaryURL, response) = try await urlSession.download(
            from: artifact.downloadURL
        )
        if let finalURL = response.url {
            guard finalURL.scheme == "https",
                  let finalHost = finalURL.host?.lowercased(),
                  artifact.allowedHosts.contains(finalHost) else {
                throw StillCoreError.untrustedInstallerURL(finalURL)
            }
        }
        if let httpResponse = response as? HTTPURLResponse,
           !(200 ... 299).contains(httpResponse.statusCode) {
            throw StillCoreError.engineDownloadFailed(httpResponse.statusCode)
        }
        try validatePEExecutable(temporaryURL)

        let destinationDirectoryURL = rootURL.appending(
            path: recipeID,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: destinationDirectoryURL,
            withIntermediateDirectories: true
        )
        let destinationURL = destinationDirectoryURL.appending(
            path: artifact.fileName
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: temporaryURL, to: destinationURL)

        return DownloadedWindowsInstaller(
            fileURL: destinationURL,
            sha256: try SHA256Verifier.digest(of: destinationURL)
        )
    }

    private func validatePEExecutable(_ fileURL: URL) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 2) ?? Data()
        guard header == Data([0x4d, 0x5a]) else {
            throw StillCoreError.invalidWindowsInstaller(fileURL)
        }
    }
}
