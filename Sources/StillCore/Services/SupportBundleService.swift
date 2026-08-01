import Foundation

public struct SupportBundleService {
    private let fileManager: FileManager
    private let homeDirectoryURL: URL

    public init(
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL
    }

    public func makeDraft(
        document: StillStoreDocument,
        engines: [EngineDescriptor],
        logsRootURL: URL = LogLocations.defaultRootURL(),
        generatedAt: Date = .now
    ) throws -> SupportBundleDraft {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let environments = document.environments.enumerated().map { index, environment in
            SanitizedEnvironment(
                reference: "environment-\(index + 1)",
                profileID: environment.profileID.map(sanitize),
                engineBuildID: environment.pinnedEngineBuildID.map(sanitize),
                graphicsBackend: environment.graphicsBackend.rawValue,
                windowsVersion: environment.windowsVersion.rawValue,
                enhancedSync: environment.enhancedSync.rawValue,
                applicationCount: document.applications.filter {
                    $0.environmentID == environment.id
                }.count,
                createdAt: environment.createdAt,
                updatedAt: environment.updatedAt
            )
        }
        let engineMetadata = engines.map {
            SanitizedEngine(
                id: sanitize($0.id),
                displayName: sanitize($0.displayName),
                version: sanitize($0.version),
                capabilities: $0.capabilities.rawValue
            )
        }
        let operations = document.operations.map {
            SanitizedOperation(
                kind: $0.kind.rawValue,
                state: $0.state.rawValue,
                createdAt: $0.createdAt,
                startedAt: $0.startedAt,
                finishedAt: $0.finishedAt,
                resultSummary: $0.resultSummary.map(sanitize),
                events: $0.events.map {
                    SanitizedEvent(occurredAt: $0.occurredAt, message: sanitize($0.message))
                }
            )
        }

        var files = [
            SupportBundleFile(
                relativePath: "Metadata/Environments.json",
                data: try encoder.encode(environments),
                summary: "Sanitized Environment configuration"
            ),
            SupportBundleFile(
                relativePath: "Metadata/Engines.json",
                data: try encoder.encode(engineMetadata),
                summary: "Installed engine identity and capabilities"
            ),
            SupportBundleFile(
                relativePath: "Activity/Operations.json",
                data: try encoder.encode(operations),
                summary: "Sanitized operation history"
            )
        ]

        files.append(contentsOf: try sanitizedLogs(at: logsRootURL))
        let listedPaths = files.map(\.relativePath).sorted()
        let manifest = SupportBundleManifest(
            formatVersion: 1,
            generatedAt: generatedAt,
            product: ProductIdentity.name,
            files: listedPaths,
            privacy: "Allowlisted metadata and redacted local logs. No Environment files, credentials, executable paths, process identifiers, or engine binaries."
        )
        files.append(SupportBundleFile(
            relativePath: "Manifest.json",
            data: try encoder.encode(manifest),
            summary: "Bundle format and privacy scope"
        ))
        return SupportBundleDraft(generatedAt: generatedAt, files: files)
    }

    public func export(_ draft: SupportBundleDraft, to destinationURL: URL) throws {
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw StillCoreError.invalidStore(
                "A file or folder already exists at the selected destination."
            )
        }
        let stagingURL = destinationURL.deletingLastPathComponent()
            .appending(path: ".still-support-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            for file in draft.files {
                let outputURL = stagingURL.appending(path: file.relativePath)
                try fileManager.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try file.data.write(to: outputURL, options: .atomic)
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    public func sanitize(_ value: String) -> String {
        var result = value.replacingOccurrences(
            of: homeDirectoryURL.standardizedFileURL.path,
            with: "~"
        )
        let replacements: [(String, String)] = [
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<email>"),
            (#"/Users/[^/\s\"']+"#, "/Users/<user>"),
            (#"(?i)C:\\users\\[^\\\s\"']+"#, #"C:\Users\<user>"#),
            (#"/Volumes/[^\s\"']+"#, "<external-path>"),
            (#"/private/(?:tmp|var)/[^\s\"']+"#, "<temporary-path>"),
            (#"(?i)(authorization\s*[:=]\s*)([^\r\n]+)"#, "$1<redacted>"),
            (#"(?i)\b(password|passwd|token|secret|cookie|session|api[_-]?key)\b\s*[:=]\s*[^\s,;]+"#, "$1=<redacted>"),
            (#"(?i)([?&](?:password|token|secret|key|session)=)[^&\s]+"#, "$1<redacted>")
        ]
        for (pattern, replacement) in replacements {
            result = result.replacingRegex(pattern, with: replacement)
        }
        return result
    }

    private func sanitizedLogs(at rootURL: URL) throws -> [SupportBundleFile] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
            )
            guard values.isRegularFile == true,
                  url.pathExtension.lowercased() == "log" else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }

        return try candidates
            .sorted { $0.1 > $1.1 }
            .prefix(20)
            .enumerated()
            .map { index, candidate in
                let data = try Data(contentsOf: candidate.0)
                let bounded = data.prefix(1_000_000)
                let text = String(decoding: bounded, as: UTF8.self)
                return SupportBundleFile(
                    relativePath: String(format: "Logs/Launch-%02d.log", index + 1),
                    data: Data(sanitize(text).utf8),
                    summary: "Redacted recent launch log"
                )
            }
    }
}

private struct SupportBundleManifest: Codable {
    let formatVersion: Int
    let generatedAt: Date
    let product: String
    let files: [String]
    let privacy: String
}

private struct SanitizedEnvironment: Codable {
    let reference: String
    let profileID: String?
    let engineBuildID: String?
    let graphicsBackend: String
    let windowsVersion: String
    let enhancedSync: String
    let applicationCount: Int
    let createdAt: Date
    let updatedAt: Date
}

private struct SanitizedEngine: Codable {
    let id: String
    let displayName: String
    let version: String
    let capabilities: UInt
}

private struct SanitizedOperation: Codable {
    let kind: String
    let state: String
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let resultSummary: String?
    let events: [SanitizedEvent]
}

private struct SanitizedEvent: Codable {
    let occurredAt: Date
    let message: String
}

private extension String {
    func replacingRegex(_ pattern: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return self }
        let range = NSRange(startIndex..<endIndex, in: self)
        return expression.stringByReplacingMatches(
            in: self,
            range: range,
            withTemplate: replacement
        )
    }
}
