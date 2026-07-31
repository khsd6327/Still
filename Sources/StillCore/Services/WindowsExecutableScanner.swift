import Foundation

public struct WindowsExecutableScanner {
    private let fileManager: FileManager
    private let maximumDepth: Int

    public init(
        fileManager: FileManager = .default,
        maximumDepth: Int = 6
    ) {
        self.fileManager = fileManager
        self.maximumDepth = maximumDepth
    }

    public func scan(bottle: Bottle) -> [InstalledWindowsApplication] {
        var applications: [String: InstalledWindowsApplication] = [:]
        let prefixURL = bottle.prefixURL.resolvingSymlinksInPath()

        for rootURL in programFilesRoots(prefixURL: prefixURL) {
            for application in scan(rootURL: rootURL, prefixURL: prefixURL) {
                applications[application.id] = application
            }
        }

        return applications.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func programFilesRoots(prefixURL: URL) -> [URL] {
        let driveCURL = prefixURL.appending(
            path: "drive_c",
            directoryHint: .isDirectory
        )
        return [
            driveCURL.appending(path: "Program Files", directoryHint: .isDirectory),
            driveCURL.appending(
                path: "Program Files (x86)",
                directoryHint: .isDirectory
            )
        ].map { $0.resolvingSymlinksInPath() }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func scan(
        rootURL: URL,
        prefixURL: URL
    ) -> [InstalledWindowsApplication] {
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var applications: [InstalledWindowsApplication] = []
        for case let executableURL as URL in enumerator {
            let normalizedExecutableURL = executableURL.resolvingSymlinksInPath()
            guard let depthRelativePath = relativePath(
                from: rootURL,
                to: normalizedExecutableURL
            ) else {
                continue
            }
            let depth = depthRelativePath.split(separator: "/").count
            if depth > maximumDepth {
                enumerator.skipDescendants()
                continue
            }

            guard normalizedExecutableURL.pathExtension.lowercased() == "exe",
                  isCandidate(
                    normalizedExecutableURL,
                    depth: depth,
                    relativePath: depthRelativePath
                  ) else {
                continue
            }

            let values = try? normalizedExecutableURL.resourceValues(
                forKeys: Set(resourceKeys)
            )
            guard values?.isRegularFile == true else { continue }

            let executableName = normalizedExecutableURL
                .deletingPathExtension()
                .lastPathComponent
            let officeName = Self.officeApplications[
                normalizedExecutableURL.lastPathComponent.uppercased()
            ]
            let source: WindowsApplicationSource = officeName == nil
                ? .standalone
                : .office
            let displayName = officeName
                ?? displayName(
                    executableName: executableName,
                    executableURL: normalizedExecutableURL
                )
            guard let prefixRelativePath = relativePath(
                from: prefixURL,
                to: normalizedExecutableURL
            ) else {
                continue
            }

            applications.append(
                InstalledWindowsApplication(
                    id: "exe-\(prefixRelativePath.lowercased())",
                    name: displayName,
                    source: source,
                    sourceIdentifier: prefixRelativePath,
                    installState: .installed,
                    installDirectoryURL: normalizedExecutableURL
                        .deletingLastPathComponent(),
                    launcherURL: normalizedExecutableURL,
                    sizeOnDisk: values?.fileSize.map(Int64.init)
                )
            )
        }

        return applications
    }

    private func relativePath(from baseURL: URL, to targetURL: URL) -> String? {
        let baseComponents = baseURL.resolvingSymlinksInPath().pathComponents
        let targetComponents = targetURL.resolvingSymlinksInPath().pathComponents
        guard targetComponents.starts(with: baseComponents) else {
            return nil
        }
        return targetComponents.dropFirst(baseComponents.count).joined(
            separator: "/"
        )
    }

    private func isCandidate(
        _ executableURL: URL,
        depth: Int,
        relativePath: String
    ) -> Bool {
        let fileName = executableURL.lastPathComponent.lowercased()
        if Self.officeApplications[fileName.uppercased()] != nil {
            return true
        }

        let normalizedRelativePath = relativePath.lowercased()
        let topLevelDirectory = normalizedRelativePath.split(
            separator: "/",
            maxSplits: 1
        ).first.map(String.init)
        if topLevelDirectory.map(
            Self.excludedTopLevelDirectories.contains
        ) == true {
            return false
        }

        let baseName = executableURL.deletingPathExtension()
            .lastPathComponent.lowercased()
        if Self.excludedExecutableNames.contains(baseName)
            || baseName.hasPrefix("unins")
            || baseName.hasSuffix("uninstaller")
            || baseName.hasSuffix("crashhandler") {
            return false
        }

        // Generic discovery is intentionally conservative. Most user-facing
        // launchers sit directly inside a vendor or product directory.
        return depth <= 2
    }

    private func displayName(
        executableName: String,
        executableURL: URL
    ) -> String {
        let normalized = executableName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        if Self.genericExecutableNames.contains(normalized.lowercased()) {
            return executableURL.deletingLastPathComponent().lastPathComponent
        }
        return normalized
    }

    private static let officeApplications: [String: String] = [
        "EXCEL.EXE": "Microsoft Excel",
        "WINWORD.EXE": "Microsoft Word",
        "POWERPNT.EXE": "Microsoft PowerPoint",
        "OUTLOOK.EXE": "Microsoft Outlook",
        "ONENOTE.EXE": "Microsoft OneNote",
        "MSACCESS.EXE": "Microsoft Access",
        "VISIO.EXE": "Microsoft Visio",
        "WINPROJ.EXE": "Microsoft Project"
    ]

    private static let excludedExecutableNames: Set<String> = [
        "setup",
        "installer",
        "install",
        "uninstall",
        "update",
        "updater",
        "updatehelper",
        "helper",
        "crashpad_handler",
        "crashreporter",
        "service",
        "steam",
        "steamservice",
        "vc_redist.x64",
        "vc_redist.x86"
    ]

    private static let excludedTopLevelDirectories: Set<String> = [
        "common files",
        "internet explorer",
        "steam",
        "windows media player",
        "windows nt"
    ]

    private static let genericExecutableNames: Set<String> = [
        "app",
        "application",
        "client",
        "launcher"
    ]
}
