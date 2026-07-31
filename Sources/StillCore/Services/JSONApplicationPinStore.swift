import Foundation

public actor JSONApplicationPinStore {
    private struct Pin: Codable {
        let bottleID: Bottle.ID
        let application: InstalledWindowsApplication
    }

    private struct StoreDocument: Codable {
        let schemaVersion: Int
        var pins: [Pin]
    }

    public let storeURL: URL
    private let fileManager: FileManager

    public init(
        rootURL: URL = JSONBottleStore.defaultRootURL(),
        fileManager: FileManager = .default
    ) {
        self.storeURL = rootURL.appending(path: "application-pins.json")
        self.fileManager = fileManager
    }

    public func applications(
        bottleID: Bottle.ID
    ) throws -> [InstalledWindowsApplication] {
        try readDocument().pins
            .filter { $0.bottleID == bottleID }
            .map(\.application)
            .map(refreshedInstallState)
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    @discardableResult
    public func pin(
        executableURL: URL,
        name: String? = nil,
        in bottle: Bottle
    ) throws -> InstalledWindowsApplication {
        let resolvedPrefixURL = bottle.prefixURL.resolvingSymlinksInPath()
        let resolvedExecutableURL = executableURL.resolvingSymlinksInPath()
        let prefixPath = normalizedDirectoryPath(resolvedPrefixURL)

        guard resolvedExecutableURL.path.hasPrefix(prefixPath),
              resolvedExecutableURL.pathExtension.lowercased() == "exe",
              fileManager.fileExists(atPath: resolvedExecutableURL.path) else {
            throw StillCoreError.invalidPinnedApplication(executableURL)
        }

        let requestedName = name?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let displayName = requestedName?.isEmpty == false
            ? requestedName!
            : resolvedExecutableURL.deletingPathExtension().lastPathComponent
        let relativePath = String(
            resolvedExecutableURL.path.dropFirst(prefixPath.count)
        )
        let application = InstalledWindowsApplication(
            id: "pin-\(relativePath.lowercased())",
            name: displayName,
            source: .pinned,
            sourceIdentifier: relativePath,
            installState: .installed,
            installDirectoryURL: resolvedExecutableURL.deletingLastPathComponent(),
            launcherURL: resolvedExecutableURL
        )

        var document = try readDocument()
        document.pins.removeAll {
            $0.bottleID == bottle.id
                && $0.application.launcherURL.resolvingSymlinksInPath()
                    == resolvedExecutableURL
        }
        document.pins.append(
            Pin(bottleID: bottle.id, application: application)
        )
        try write(document)
        return application
    }

    public func remove(
        applicationID: InstalledWindowsApplication.ID,
        bottleID: Bottle.ID
    ) throws {
        var document = try readDocument()
        document.pins.removeAll {
            $0.bottleID == bottleID && $0.application.id == applicationID
        }
        try write(document)
    }

    private func refreshedInstallState(
        _ application: InstalledWindowsApplication
    ) -> InstalledWindowsApplication {
        InstalledWindowsApplication(
            id: application.id,
            name: application.name,
            source: application.source,
            sourceIdentifier: application.sourceIdentifier,
            installState: fileManager.fileExists(
                atPath: application.launcherURL.path
            ) ? .installed : .unknown,
            installDirectoryURL: application.installDirectoryURL,
            launcherURL: application.launcherURL,
            launchArguments: application.launchArguments,
            sizeOnDisk: application.sizeOnDisk
        )
    }

    private func normalizedDirectoryPath(_ url: URL) -> String {
        url.path.hasSuffix("/") ? url.path : url.path + "/"
    }

    private func readDocument() throws -> StoreDocument {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return StoreDocument(schemaVersion: 1, pins: [])
        }
        let data = try Data(contentsOf: storeURL)
        let document = try JSONDecoder().decode(StoreDocument.self, from: data)
        guard document.schemaVersion == 1 else {
            throw StillCoreError.unsupportedApplicationPinSchema(
                document.schemaVersion
            )
        }
        return document
    }

    private func write(_ document: StoreDocument) throws {
        try fileManager.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        try encoder.encode(document).write(to: storeURL, options: .atomic)
    }
}
