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
