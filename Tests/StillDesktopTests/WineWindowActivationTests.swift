import CoreGraphics
import StillCore
import XCTest
#if SWIFT_PACKAGE
@testable import StillDesktop
#else
@testable import Still
#endif

@MainActor
final class WineWindowActivationTests: XCTestCase {
    func testActivatesActualWindowOwnerInsteadOfMinimumObservedPID() {
        let system = FakeNativeWindowSystemClient()
        system.candidates = [candidate(id: 8, pid: 40, title: "Steam", area: 800)]
        system.runningApplicationResult = true
        system.verificationResult = true
        let activator = WineWindowActivator(system: system)

        XCTAssertEqual(
            activator.activate(
                applicationName: "Steam",
                processIdentities: [identity(10), identity(40)]
            ),
            .activated(method: .runningApplication, windowIdentifier: 8)
        )
        XCTAssertEqual(system.runningApplicationPIDs, [40])
    }

    func testReturnsPermissionStateOnlyAfterRunningApplicationPathFails() {
        let system = FakeNativeWindowSystemClient()
        system.candidates = [candidate(id: 10, pid: 42, title: "Steam", area: 800)]
        system.accessibilityTrusted = false
        let activator = WineWindowActivator(system: system)

        XCTAssertEqual(
            activator.activate(
                applicationName: "Steam",
                processIdentities: [identity(42)]
            ),
            .accessibilityPermissionRequired
        )
        XCTAssertEqual(system.runningApplicationPIDs, [42])
        XCTAssertTrue(system.accessibilityCandidates.isEmpty)
    }

    func testUsesAccessibilityOnlyWhenTrustedAndVerifiesResult() {
        let system = FakeNativeWindowSystemClient()
        let window = candidate(id: 11, pid: 43, title: "Steam", area: 800)
        system.candidates = [window]
        system.accessibilityTrusted = true
        system.accessibilityResult = true
        system.verificationResult = true
        let activator = WineWindowActivator(system: system)

        XCTAssertEqual(
            activator.activate(
                applicationName: "Steam",
                processIdentities: [identity(43)]
            ),
            .activated(method: .accessibility, windowIdentifier: 11)
        )
        XCTAssertEqual(system.accessibilityCandidates, [window])
    }

    func testRejectsAmbiguousEquivalentWindowsFromDifferentOwners() {
        let system = FakeNativeWindowSystemClient()
        system.candidates = [
            candidate(id: 12, pid: 44, title: "Steam", area: 800),
            candidate(id: 13, pid: 45, title: "Steam", area: 800)
        ]
        let activator = WineWindowActivator(system: system)

        XCTAssertEqual(
            activator.activate(
                applicationName: "Steam",
                processIdentities: [identity(44), identity(45)]
            ),
            .ambiguousWindow
        )
        XCTAssertTrue(system.runningApplicationPIDs.isEmpty)
    }

    private func identity(_ pid: Int32) -> HostProcessIdentity {
        HostProcessIdentity(processIdentifier: pid, startedAt: Date(timeIntervalSince1970: 1))
    }

    private func candidate(
        id: CGWindowID,
        pid: Int32,
        title: String,
        area: CGFloat
    ) -> NativeWindowCandidate {
        NativeWindowCandidate(
            windowIdentifier: id,
            ownerProcessIdentifier: pid,
            title: title,
            bounds: CGRect(x: 0, y: 0, width: area, height: 100),
            layer: 0,
            isOnScreen: true
        )
    }
}

@MainActor
private final class FakeNativeWindowSystemClient: NativeWindowSystemClient {
    var accessibilityTrusted = false
    var candidates: [NativeWindowCandidate] = []
    var runningApplicationResult = false
    var accessibilityResult = false
    var verificationResult = false
    var runningApplicationPIDs: [Int32] = []
    var accessibilityCandidates: [NativeWindowCandidate] = []
    var permissionRequestCount = 0

    func windows(ownedBy processIdentifiers: Set<Int32>) -> [NativeWindowCandidate] {
        candidates.filter { processIdentifiers.contains($0.ownerProcessIdentifier) }
    }

    func activateRunningApplication(processIdentifier: Int32) -> Bool {
        runningApplicationPIDs.append(processIdentifier)
        return runningApplicationResult
    }

    func raiseAccessibilityWindow(_ candidate: NativeWindowCandidate) -> Bool {
        accessibilityCandidates.append(candidate)
        return accessibilityResult
    }

    func verifyActivation(of candidate: NativeWindowCandidate) -> Bool {
        verificationResult
    }

    func requestAccessibilityPermission() {
        permissionRequestCount += 1
    }
}
