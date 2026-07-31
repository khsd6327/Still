import XCTest
@testable import StillCore

final class ApplicationRecipeTests: XCTestCase {
    func testSteamUsesCurrentStagingClientProfile() {
        let recipe = BundledApplicationRecipes.steam

        XCTAssertEqual(recipe.preferredEngineFamily, .wineStaging)
        XCTAssertEqual(recipe.windowsVersion, .windows10)
        XCTAssertEqual(recipe.graphicsBackend, .wineD3D)
        XCTAssertNotNil(recipe.installer)
        XCTAssertEqual(
            SteamBootstrapper.launchArguments(
                for: Bottle(
                    name: "Steam",
                    prefixURL: URL(filePath: "/tmp/steam")
                )
            ),
            ["-cef-disable-gpu", "-cef-disable-gpu-compositing"]
        )
        XCTAssertEqual(
            SteamBootstrapper.launchArguments(
                for: Bottle(
                    name: "Steam",
                    prefixURL: URL(filePath: "/tmp/steam"),
                    graphicsBackend: .dxmt
                )
            ),
            []
        )
        XCTAssertEqual(
            SteamBootstrapper.launchArguments(
                for: Bottle(
                    name: "Steam",
                    prefixURL: URL(filePath: "/tmp/steam"),
                    graphicsBackend: .d3dMetal
                )
            ),
            []
        )
    }
}
