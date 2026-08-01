import Foundation
import XCTest
@testable import StillCore

final class EnvironmentOwnershipServiceTests: XCTestCase {
    func testManagedMarkerRequiresExactStoreEnvironmentAndNonce() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = EnvironmentOwnershipService(managedRootURL: root)
        let storeIdentifier = UUID()
        let environment = WindowsEnvironment(
            id: UUID(),
            name: "Managed",
            prefixURL: service.managedPrefixURL(for: UUID()),
            ownership: .managed,
            managementNonce: UUID()
        )
        let corrected = WindowsEnvironment(
            id: environment.id,
            name: environment.name,
            prefixURL: service.managedPrefixURL(for: environment.id),
            ownership: .managed,
            managementNonce: environment.managementNonce
        )

        try service.writeMarker(for: corrected, storeIdentifier: storeIdentifier)
        XCTAssertNoThrow(
            try service.validateManagedOwnership(
                of: corrected,
                storeIdentifier: storeIdentifier
            )
        )
        XCTAssertThrowsError(
            try service.validateManagedOwnership(of: corrected, storeIdentifier: UUID())
        )

        var wrongNonce = corrected
        wrongNonce.managementNonce = UUID()
        XCTAssertThrowsError(
            try service.validateManagedOwnership(
                of: wrongNonce,
                storeIdentifier: storeIdentifier
            )
        )
    }

    func testManagedMarkerRejectsUnexpectedPathAndSymlink() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = EnvironmentOwnershipService(managedRootURL: root)
        let environmentID = UUID()
        let unexpected = WindowsEnvironment(
            id: environmentID,
            name: "Unexpected",
            prefixURL: root.appending(path: "Different"),
            ownership: .managed,
            managementNonce: UUID()
        )
        XCTAssertThrowsError(
            try service.writeMarker(for: unexpected, storeIdentifier: UUID())
        )

        let destination = root.appending(path: "Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let symlink = service.managedPrefixURL(for: environmentID)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: destination)
        var linked = unexpected
        linked.prefixURL = symlink
        XCTAssertThrowsError(
            try service.writeMarker(for: linked, storeIdentifier: UUID())
        )
    }

    func testLegacyEnvironmentDecodesWithUnknownOwnership() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Legacy",
          "prefixURL": "file:///tmp/legacy/",
          "graphicsBackend": "wineD3D",
          "windowsVersion": "windows10",
          "enhancedSync": "automatic",
          "createdAt": 0,
          "updatedAt": 0
        }
        """
        let environment = try JSONDecoder().decode(
            WindowsEnvironment.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(environment.ownership, .unknown)
        XCTAssertNil(environment.managementNonce)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "StillOwnershipTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
