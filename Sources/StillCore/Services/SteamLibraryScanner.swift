import Foundation

public struct SteamLibraryScanner {
    private let fileManager: FileManager
    private let parser: ValveKeyValueParser

    public init(
        fileManager: FileManager = .default,
        parser: ValveKeyValueParser = ValveKeyValueParser()
    ) {
        self.fileManager = fileManager
        self.parser = parser
    }

    public func scan(bottle: Bottle) throws -> [InstalledWindowsApplication] {
        guard let steamRootURL = steamRoot(in: bottle) else { return [] }
        let launcherURL = steamRootURL.appending(path: "steam.exe")
        guard fileManager.fileExists(atPath: launcherURL.path) else { return [] }

        var steamAppsURLs = [
            steamRootURL.appending(path: "steamapps", directoryHint: .isDirectory)
        ]
        steamAppsURLs.append(
            contentsOf: try additionalSteamAppsURLs(
                primarySteamAppsURL: steamAppsURLs[0],
                bottle: bottle
            )
        )

        var applications: [String: InstalledWindowsApplication] = [:]
        for steamAppsURL in steamAppsURLs {
            for application in try scan(
                steamAppsURL: steamAppsURL,
                launcherURL: launcherURL
            ) {
                applications[application.id] = application
            }
        }

        return applications.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func steamRoot(in bottle: Bottle) -> URL? {
        let candidates = [
            bottle.prefixURL.appending(
                path: "drive_c/Program Files (x86)/Steam",
                directoryHint: .isDirectory
            ),
            bottle.prefixURL.appending(
                path: "drive_c/Program Files/Steam",
                directoryHint: .isDirectory
            )
        ]
        return candidates.first {
            fileManager.fileExists(atPath: $0.appending(path: "steam.exe").path)
        }
    }

    private func scan(
        steamAppsURL: URL,
        launcherURL: URL
    ) throws -> [InstalledWindowsApplication] {
        guard fileManager.fileExists(atPath: steamAppsURL.path) else { return [] }
        let manifestURLs = try fileManager.contentsOfDirectory(
            at: steamAppsURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("appmanifest_")
                && $0.pathExtension == "acf"
        }

        return try manifestURLs.compactMap { manifestURL in
            let text = try String(contentsOf: manifestURL, encoding: .utf8)
            let document = try parser.parse(text)
            guard let appState = document["AppState"],
                  let appID = appState["appid"]?.stringValue,
                  let name = appState["name"]?.stringValue,
                  let installDirectory = appState["installdir"]?.stringValue else {
                return nil
            }

            let installDirectoryURL = steamAppsURL
                .appending(path: "common", directoryHint: .isDirectory)
                .appending(path: installDirectory, directoryHint: .isDirectory)
            let stateFlags = UInt64(
                appState["StateFlags"]?.stringValue ?? ""
            ) ?? 0
            let state = installState(
                stateFlags: stateFlags,
                installDirectoryURL: installDirectoryURL
            )
            let size = Int64(appState["SizeOnDisk"]?.stringValue ?? "")

            return InstalledWindowsApplication(
                id: "steam-\(appID)",
                name: name,
                source: .steam,
                sourceIdentifier: appID,
                installState: state,
                installDirectoryURL: installDirectoryURL,
                launcherURL: launcherURL,
                launchArguments: ["-applaunch", appID],
                sizeOnDisk: size
            )
        }
    }

    private func installState(
        stateFlags: UInt64,
        installDirectoryURL: URL
    ) -> WindowsApplicationInstallState {
        if stateFlags & 4 == 4,
           fileManager.fileExists(atPath: installDirectoryURL.path) {
            return .installed
        }
        if stateFlags & 2 == 2 || stateFlags & 512 == 512 {
            return .downloading
        }
        if stateFlags & 8 == 8 || stateFlags & 1024 == 1024 {
            return .needsUpdate
        }
        return .unknown
    }

    private func additionalSteamAppsURLs(
        primarySteamAppsURL: URL,
        bottle: Bottle
    ) throws -> [URL] {
        let libraryFileURL = primarySteamAppsURL.appending(
            path: "libraryfolders.vdf"
        )
        guard fileManager.fileExists(atPath: libraryFileURL.path) else {
            return []
        }

        let text = try String(contentsOf: libraryFileURL, encoding: .utf8)
        let document = try parser.parse(text)
        guard let libraryFolders = document["libraryfolders"],
              case .object(let libraries) = libraryFolders else {
            return []
        }

        return libraries.values.compactMap { library in
            guard let windowsPath = library["path"]?.stringValue,
                  let rootURL = wineURL(
                    from: windowsPath,
                    prefixURL: bottle.prefixURL
                  ) else {
                return nil
            }
            let steamAppsURL = rootURL.appending(
                path: "steamapps",
                directoryHint: .isDirectory
            )
            return steamAppsURL.standardizedFileURL
                == primarySteamAppsURL.standardizedFileURL
                ? nil
                : steamAppsURL
        }
    }

    private func wineURL(from path: String, prefixURL: URL) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\\\", with: "\\")
        guard normalized.count >= 3 else { return nil }
        let characters = Array(normalized)
        guard characters[1] == ":", characters[2] == "\\" else { return nil }

        let drive = String(characters[0]).lowercased()
        let remainder = String(characters.dropFirst(3))
            .replacingOccurrences(of: "\\", with: "/")
        if drive == "c" {
            return prefixURL
                .appending(path: "drive_c", directoryHint: .isDirectory)
                .appending(path: remainder, directoryHint: .isDirectory)
        }

        let driveLinkURL = prefixURL
            .appending(path: "dosdevices", directoryHint: .isDirectory)
            .appending(path: "\(drive):")
        guard let destination = try? fileManager.destinationOfSymbolicLink(
            atPath: driveLinkURL.path
        ) else {
            return nil
        }
        let driveRootURL = URL(
            filePath: destination,
            relativeTo: driveLinkURL.deletingLastPathComponent()
        ).standardizedFileURL
        return driveRootURL.appending(
            path: remainder,
            directoryHint: .isDirectory
        )
    }
}
