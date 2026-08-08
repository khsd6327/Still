import StillCore
import XCTest
#if SWIFT_PACKAGE
@testable import StillDesktop
#else
@testable import Still
#endif

@MainActor
final class AppModelSelectionTests: XCTestCase {
    func testChangingLibraryScopeSelectsAnApplicationVisibleInThatScope() {
        let model = AppModel()
        let environmentID = UUID()
        let launcher = application(
            name: "Steam",
            category: .launcher,
            environmentID: environmentID
        )
        let game = application(
            name: "Game",
            category: .game,
            environmentID: environmentID
        )
        model.applications = [launcher, game]
        model.destination = .allApplications
        model.selectedApplicationID = launcher.id

        model.destination = .games

        XCTAssertEqual(model.selectedApplicationID, game.id)
        XCTAssertEqual(model.selectedApplication?.id, game.id)
    }

    func testSearchClearsASelectionThatIsNoLongerVisible() {
        let model = AppModel()
        let environmentID = UUID()
        let first = application(
            name: "Alpha",
            category: .productivity,
            environmentID: environmentID
        )
        let second = application(
            name: "Beta",
            category: .productivity,
            environmentID: environmentID
        )
        model.applications = [first, second]
        model.destination = .allApplications
        model.selectedApplicationID = first.id

        model.searchText = "Beta"

        XCTAssertEqual(model.selectedApplicationID, second.id)
    }

    private func application(
        name: String,
        category: LibraryApplicationCategory,
        environmentID: UUID
    ) -> LibraryApplication {
        LibraryApplication(
            environmentID: environmentID,
            name: name,
            category: category
        )
    }
}
