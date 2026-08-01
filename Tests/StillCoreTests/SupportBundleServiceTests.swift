import Foundation
import XCTest
@testable import StillCore

final class SupportBundleServiceTests: XCTestCase {
    func testPreviewAndExportContainTheSameAllowlistedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let home = root.appending(path: "Users/Example", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "user@example.com token=secret /Users/Example/Documents/file.exe"
            .write(to: logs.appending(path: "launch.log"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = WindowsEnvironment(
            name: "Private Name",
            prefixURL: home.appending(path: "Environment")
        )
        var operation = StillOperation(kind: .backup, environmentID: environment.id)
        try operation.transition(to: .running)
        operation.appendEvent("Authorization: Bearer private-value")
        try operation.transition(to: .succeeded, resultSummary: "Saved in /Users/Example/Desktop")
        let document = StillStoreDocument(
            environments: [environment],
            operations: [operation]
        )
        let service = SupportBundleService(homeDirectoryURL: home)
        let draft = try service.makeDraft(
            document: document,
            engines: [],
            logsRootURL: logs,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let destination = root.appending(path: "Evidence.stillsupport", directoryHint: .isDirectory)

        try service.export(draft, to: destination)

        let exportedPaths = try FileManager.default
            .subpathsOfDirectory(atPath: destination.path)
            .filter { relativePath in
                try destination.appending(path: relativePath)
                    .resourceValues(forKeys: [.isRegularFileKey])
                    .isRegularFile == true
            }
            .sorted()
        XCTAssertEqual(exportedPaths, draft.previewEntries.map(\.relativePath).sorted())
        for file in draft.files {
            XCTAssertEqual(
                try Data(contentsOf: destination.appending(path: file.relativePath)),
                file.data
            )
        }
    }

    func testSanitizerRemovesCredentialsAndPersonalLocations() throws {
        let home = URL(fileURLWithPath: "/Users/Example")
        let service = SupportBundleService(homeDirectoryURL: home)
        let value = """
        account@example.com
        /Users/Example/Documents/private.exe
        C:\\users\\Example\\Desktop\\secret.exe
        token=abc123
        Cookie: session-value
        https://example.test/path?token=abc123&mode=test
        """

        let sanitized = service.sanitize(value)

        XCTAssertFalse(sanitized.contains("account@example.com"))
        XCTAssertFalse(sanitized.contains("Example/Documents"))
        XCTAssertFalse(sanitized.contains("Example\\Desktop"))
        XCTAssertFalse(sanitized.contains("abc123"))
        XCTAssertFalse(sanitized.contains("session-value"))
        XCTAssertTrue(sanitized.contains("<redacted>"))
    }

    func testExportRefusesToOverwriteAnExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Existing.stillsupport")
        try Data("keep".utf8).write(to: destination)
        let draft = SupportBundleDraft(files: [
            SupportBundleFile(relativePath: "Manifest.json", data: Data("new".utf8), summary: "Manifest")
        ])

        XCTAssertThrowsError(try SupportBundleService().export(draft, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
    }
}
