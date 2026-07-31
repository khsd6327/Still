import Foundation
import XCTest
@testable import StillCore

final class WindowsExecutableScannerTests: XCTestCase {
    private var temporaryURL: URL!

    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "StillExecutableScanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    func testDiscoversOfficeAndStandaloneApplications() throws {
        let prefixURL = temporaryURL.appending(path: "prefix")
        let officeURL = prefixURL.appending(
            path: "drive_c/Program Files/Microsoft Office/root/Office16/EXCEL.EXE"
        )
        let appURL = prefixURL.appending(
            path: "drive_c/Program Files/Acme Notes/AcmeNotes.exe"
        )
        try createExecutable(at: officeURL)
        try createExecutable(at: appURL)

        let applications = WindowsExecutableScanner().scan(
            bottle: Bottle(name: "Productivity", prefixURL: prefixURL)
        )

        XCTAssertEqual(applications.count, 2)
        XCTAssertEqual(
            applications.first(
                where: { $0.launcherURL.lastPathComponent == "EXCEL.EXE" }
            )?.name,
            "Microsoft Excel"
        )
        XCTAssertEqual(
            applications.first(
                where: { $0.launcherURL.lastPathComponent == "EXCEL.EXE" }
            )?.source,
            .office
        )
        XCTAssertEqual(
            applications.first(
                where: { $0.launcherURL.lastPathComponent == "AcmeNotes.exe" }
            )?.source,
            .standalone
        )
    }

    func testExcludesInstallersHelpersAndDeepUnknownExecutables() throws {
        let prefixURL = temporaryURL.appending(path: "prefix")
        let programFilesURL = prefixURL.appending(
            path: "drive_c/Program Files"
        )
        try createExecutable(
            at: programFilesURL.appending(path: "Vendor/setup.exe")
        )
        try createExecutable(
            at: programFilesURL.appending(path: "Vendor/helper.exe")
        )
        try createExecutable(
            at: programFilesURL.appending(
                path: "Vendor/runtime/components/internal.exe"
            )
        )

        let applications = WindowsExecutableScanner().scan(
            bottle: Bottle(name: "Empty", prefixURL: prefixURL)
        )

        XCTAssertTrue(applications.isEmpty)
    }

    func testUsesProductDirectoryForGenericLauncherName() throws {
        let prefixURL = temporaryURL.appending(path: "prefix")
        let launcherURL = prefixURL.appending(
            path: "drive_c/Program Files/Example Game/launcher.exe"
        )
        try createExecutable(at: launcherURL)

        let application = try XCTUnwrap(
            WindowsExecutableScanner().scan(
                bottle: Bottle(name: "Games", prefixURL: prefixURL)
            ).first
        )

        XCTAssertEqual(application.name, "Example Game")
    }

    func testExcludesSteamClientAndWineSystemExecutables() throws {
        let prefixURL = temporaryURL.appending(path: "prefix")
        let excludedPaths = [
            "drive_c/Program Files (x86)/Steam/gameoverlayui.exe",
            "drive_c/Program Files (x86)/Steam/gameoverlayui64.exe",
            "drive_c/Program Files (x86)/Steam/steamerrorreporter.exe",
            "drive_c/Program Files (x86)/Steam/steamerrorreporter64.exe",
            "drive_c/Program Files (x86)/Steam/steamsysinfo.exe",
            "drive_c/Program Files (x86)/Steam/streaming_client.exe",
            "drive_c/Program Files (x86)/Steam/WriteMiniDump.exe",
            "drive_c/Program Files/Internet Explorer/iexplore.exe",
            "drive_c/Program Files (x86)/Internet Explorer/iexplore.exe"
        ]
        for path in excludedPaths {
            try createExecutable(at: prefixURL.appending(path: path))
        }

        let applications = WindowsExecutableScanner().scan(
            bottle: Bottle(name: "Steam", prefixURL: prefixURL)
        )

        XCTAssertTrue(
            applications.isEmpty,
            "Unexpected system executables: \(applications.map(\.sourceIdentifier))"
        )
    }

    private func createExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("MZ executable".utf8).write(to: url)
    }
}
