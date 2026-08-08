import AppKit
import StillCore
import XCTest
#if SWIFT_PACKAGE
@testable import StillDesktop
#else
@testable import Still
#endif

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
    func testNoLiveActivityTerminatesRegardlessOfPreference() {
        for behavior in CloseRunningBehavior.allCases {
            XCTAssertEqual(
                ApplicationTerminationPolicy.action(
                    hasLiveWineActivity: false,
                    closeRunningBehavior: behavior
                ),
                .terminateNow
            )
        }
    }

    func testLiveActivityUsesConfiguredTerminationBehavior() {
        XCTAssertEqual(
            ApplicationTerminationPolicy.action(
                hasLiveWineActivity: true,
                closeRunningBehavior: .ask
            ),
            .ask
        )
        XCTAssertEqual(
            ApplicationTerminationPolicy.action(
                hasLiveWineActivity: true,
                closeRunningBehavior: .stopAndClose
            ),
            .requestNormalStop
        )
        XCTAssertEqual(
            ApplicationTerminationPolicy.action(
                hasLiveWineActivity: true,
                closeRunningBehavior: .leaveRunning
            ),
            .terminateNow
        )
    }

    func testMainWindowCloseRequestsApplicationTerminationAndKeepsWindowOpen() {
        var requestCount = 0
        let coordinator = WindowCloseGuard.Coordinator {
            requestCount += 1
        }

        XCTAssertFalse(coordinator.windowShouldClose(NSWindow()))
        XCTAssertEqual(requestCount, 1)
    }

    func testStoppedApplicationClearsPendingWindowActivationNotice() {
        let model = AppModel()
        let applicationID = UUID()
        model.pendingWindowControlApplicationID = applicationID
        model.launchNotice = "Permission required"

        model.reconcileWindowActivationNotice(activeApplicationIDs: [])

        XCTAssertNil(model.pendingWindowControlApplicationID)
        XCTAssertNil(model.launchNotice)
    }

    func testRunningApplicationKeepsPendingWindowActivationNotice() {
        let model = AppModel()
        let applicationID = UUID()
        model.pendingWindowControlApplicationID = applicationID
        model.launchNotice = "Permission required"

        model.reconcileWindowActivationNotice(activeApplicationIDs: [applicationID])

        XCTAssertEqual(model.pendingWindowControlApplicationID, applicationID)
        XCTAssertEqual(model.launchNotice, "Permission required")
    }
}
