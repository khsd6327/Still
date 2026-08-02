import Foundation

public struct TarXZArchiveExtractor: Sendable {
    public init() {}

    public func extract(archiveURL: URL, destinationURL: URL) throws {
        let entries = try listEntries(archiveURL: archiveURL)
        try validate(entries: entries)
        try runTar([
            "-xJf", archiveURL.path,
            "-C", destinationURL.path
        ])
        try validateExtractedTree(at: destinationURL)
    }

    private func listEntries(archiveURL: URL) throws -> [String] {
        let output = try runTar(["-tJf", archiveURL.path], captureOutput: true)
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func validate(entries: [String]) throws {
        guard !entries.isEmpty else {
            throw StillCoreError.invalidEngineArchive("The archive is empty.")
        }

        for entry in entries {
            let normalized = entry.replacingOccurrences(of: "\\", with: "/")
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            if normalized.hasPrefix("/")
                || components.contains("..")
                || normalized.contains("\0") {
                throw StillCoreError.invalidEngineArchive(
                    "Unsafe archive entry: \(entry)"
                )
            }
        }
    }

    private func validateExtractedTree(at rootURL: URL) throws {
        let rootPath = rootURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
            ],
            options: []
        ) else {
            throw StillCoreError.invalidEngineArchive(
                "The extracted archive could not be enumerated."
            )
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
            ])
            if values.isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(
                    atPath: url.path
                )
                let resolved: URL
                if target.hasPrefix("/") {
                    resolved = URL(filePath: target)
                } else {
                    resolved = url.deletingLastPathComponent().appending(path: target)
                }
                let resolvedPath = resolved.standardizedFileURL.path
                guard resolvedPath == rootPath || resolvedPath.hasPrefix(prefix) else {
                    throw StillCoreError.invalidEngineArchive(
                        "An extracted symbolic link leaves the engine root."
                    )
                }
                enumerator.skipDescendants()
                continue
            }
            guard values.isDirectory == true || values.isRegularFile == true else {
                throw StillCoreError.invalidEngineArchive(
                    "The engine archive contains a special filesystem entry."
                )
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else {
                throw StillCoreError.invalidEngineArchive(
                    "An extracted entry leaves the engine root."
                )
            }
        }
    }

    @discardableResult
    private func runTar(
        _ arguments: [String],
        captureOutput: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        if captureOutput {
            process.standardOutput = outputPipe
        }
        process.standardError = errorPipe

        try process.run()
        let outputData = captureOutput
            ? outputPipe.fileHandleForReading.readDataToEndOfFile()
            : Data()
        process.waitUntilExit()

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
            throw StillCoreError.archiveExtractionFailed(message)
        }

        guard captureOutput else { return "" }
        return String(decoding: outputData, as: UTF8.self)
    }
}
