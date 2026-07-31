import Foundation
import XCTest
@testable import StillCore

final class JSONApplicationPinStoreTests: XCTestCase {
    func testPinsReloadsAndRemovesExecutable() async throws {
        let rootURL = temporaryRoot()
        let prefixURL = rootURL.appending(path: "Bottle")
        let executableURL = prefixURL.appending(
            path: "drive_c/Program Files/Example/Example.exe"
        )
        try createExecutable(at: executableURL)
        let bottle = Bottle(name: "Example", prefixURL: prefixURL)
        let store = JSONApplicationPinStore(rootURL: rootURL)

        let pinned = try await store.pin(
            executableURL: executableURL,
            name: "Example App",
            in: bottle
        )
        let reloaded = try await JSONApplicationPinStore(
            rootURL: rootURL
        ).applications(bottleID: bottle.id)

        XCTAssertEqual(reloaded, [pinned])

        try await store.remove(
            applicationID: pinned.id,
            bottleID: bottle.id
        )
        let remaining = try await store.applications(bottleID: bottle.id)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMarksMissingPinnedExecutableUnknown() async throws {
        let rootURL = temporaryRoot()
        let prefixURL = rootURL.appending(path: "Bottle")
        let executableURL = prefixURL.appending(path: "drive_c/App/App.exe")
        try createExecutable(at: executableURL)
        let bottle = Bottle(name: "Example", prefixURL: prefixURL)
        let store = JSONApplicationPinStore(rootURL: rootURL)
        _ = try await store.pin(executableURL: executableURL, in: bottle)
        try FileManager.default.removeItem(at: executableURL)

        let applications = try await store.applications(bottleID: bottle.id)

        XCTAssertEqual(applications.first?.installState, .unknown)
    }

    func testRejectsExecutableOutsideBottle() async throws {
        let rootURL = temporaryRoot()
        let prefixURL = rootURL.appending(path: "Bottle")
        let executableURL = rootURL.appending(path: "Outside.exe")
        try createExecutable(at: executableURL)
        let bottle = Bottle(name: "Example", prefixURL: prefixURL)
        let store = JSONApplicationPinStore(rootURL: rootURL)

        do {
            _ = try await store.pin(
                executableURL: executableURL,
                in: bottle
            )
            XCTFail("Expected an invalid pinned application error.")
        } catch let error as StillCoreError {
            XCTAssertEqual(
                error,
                .invalidPinnedApplication(executableURL)
            )
        }
    }

    private func createExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("MZ executable".utf8).write(to: url)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "StillPinStore-\(UUID().uuidString)")
    }
}
