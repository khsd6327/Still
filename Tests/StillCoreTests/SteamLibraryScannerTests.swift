import Foundation
import XCTest
@testable import StillCore

final class SteamLibraryScannerTests: XCTestCase {
    private var temporaryURL: URL!

    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "StillSteamScanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    func testRecognizesInstalledSteamGameFromManifest() throws {
        let prefixURL = temporaryURL.appending(path: "prefix")
        let steamURL = prefixURL.appending(
            path: "drive_c/Program Files (x86)/Steam"
        )
        let steamAppsURL = steamURL.appending(path: "steamapps")
        let installURL = steamAppsURL.appending(path: "common/No Man's Sky")
        try FileManager.default.createDirectory(
            at: installURL,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: steamURL.appending(path: "steam.exe").path,
            contents: Data("MZ".utf8)
        )
        let manifest = #"""
        "AppState"
        {
            "appid" "275850"
            "name" "No Man's Sky"
            "StateFlags" "4"
            "installdir" "No Man's Sky"
            "SizeOnDisk" "29851414890"
        }
        """#
        try manifest.write(
            to: steamAppsURL.appending(path: "appmanifest_275850.acf"),
            atomically: true,
            encoding: .utf8
        )
        let bottle = Bottle(name: "Steam", prefixURL: prefixURL)

        let applications = try SteamLibraryScanner().scan(bottle: bottle)

        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(applications[0].name, "No Man's Sky")
        XCTAssertEqual(applications[0].installState, .installed)
        XCTAssertEqual(applications[0].launchArguments, ["-applaunch", "275850"])
        XCTAssertEqual(applications[0].sizeOnDisk, 29_851_414_890)
    }

    func testReportsIncompleteManifestAsDownloading() throws {
        let prefixURL = temporaryURL.appending(path: "prefix")
        let steamURL = prefixURL.appending(
            path: "drive_c/Program Files (x86)/Steam"
        )
        let steamAppsURL = steamURL.appending(path: "steamapps")
        try FileManager.default.createDirectory(
            at: steamAppsURL,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: steamURL.appending(path: "steam.exe").path,
            contents: Data("MZ".utf8)
        )
        let manifest = #"""
        "AppState"
        {
            "appid" "123"
            "name" "Downloading Game"
            "StateFlags" "2"
            "installdir" "Downloading Game"
        }
        """#
        try manifest.write(
            to: steamAppsURL.appending(path: "appmanifest_123.acf"),
            atomically: true,
            encoding: .utf8
        )

        let applications = try SteamLibraryScanner().scan(
            bottle: Bottle(name: "Steam", prefixURL: prefixURL)
        )

        XCTAssertEqual(applications.first?.installState, .downloading)
    }

    func testExcludesSteamworksCommonRedistributables() throws {
        let prefixURL = temporaryURL.appending(path: "prefix")
        let steamURL = prefixURL.appending(
            path: "drive_c/Program Files (x86)/Steam"
        )
        let steamAppsURL = steamURL.appending(path: "steamapps")
        try FileManager.default.createDirectory(
            at: steamAppsURL,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: steamURL.appending(path: "steam.exe").path,
            contents: Data("MZ".utf8)
        )
        let manifest = #"""
        "AppState"
        {
            "appid" "228980"
            "name" "Steamworks Common Redistributables"
            "StateFlags" "4"
            "installdir" "Steamworks Shared"
        }
        """#
        try manifest.write(
            to: steamAppsURL.appending(path: "appmanifest_228980.acf"),
            atomically: true,
            encoding: .utf8
        )

        let applications = try SteamLibraryScanner().scan(
            bottle: Bottle(name: "Steam", prefixURL: prefixURL)
        )

        XCTAssertTrue(applications.isEmpty)
    }

    func testMalformedManifestDoesNotSuppressValidGames() throws {
        let prefixURL = temporaryURL.appending(path: "prefix")
        let steamURL = prefixURL.appending(
            path: "drive_c/Program Files (x86)/Steam"
        )
        let steamAppsURL = steamURL.appending(path: "steamapps")
        let installURL = steamAppsURL.appending(path: "common/Valid Game")
        try FileManager.default.createDirectory(
            at: installURL,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: steamURL.appending(path: "steam.exe").path,
            contents: Data("MZ".utf8)
        )
        try #""AppState" { "appid""#.write(
            to: steamAppsURL.appending(path: "appmanifest_100.acf"),
            atomically: true,
            encoding: .utf8
        )
        let validManifest = #"""
        "AppState"
        {
            "appid" "200"
            "name" "Valid Game"
            "StateFlags" "4"
            "installdir" "Valid Game"
        }
        """#
        try validManifest.write(
            to: steamAppsURL.appending(path: "appmanifest_200.acf"),
            atomically: true,
            encoding: .utf8
        )

        let applications = try SteamLibraryScanner().scan(
            bottle: Bottle(name: "Steam", prefixURL: prefixURL)
        )

        XCTAssertEqual(applications.map(\.id), ["steam-200"])
        XCTAssertEqual(applications.first?.name, "Valid Game")
    }
}
