import XCTest
@testable import StillCore

final class ApplicationRecipeTests: XCTestCase {
    func testSteamUsesCurrentStagingClientProfile() {
        let recipe = BundledApplicationRecipes.steam

        XCTAssertEqual(recipe.preferredEngineFamily, .wineStaging)
        XCTAssertEqual(recipe.windowsVersion, .windows10)
        XCTAssertEqual(recipe.graphicsBackend, .wineD3D)
        XCTAssertNotNil(recipe.installer)
        XCTAssertEqual(recipe.installer?.acceptedFileNames, ["steamsetup.exe"])
        XCTAssertEqual(recipe.installer?.arguments, ["/S"])
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

    func testSteamDXMTClientEnablesScopedRawANGLEBridge() {
        let bottle = Bottle(
            name: "Steam",
            prefixURL: URL(filePath: "/tmp/steam"),
            graphicsBackend: .dxmt
        )

        XCTAssertEqual(
            SteamBootstrapper.launchEnvironment(
                for: bottle,
                executableURL: URL(filePath: "/tmp/steam/steam.exe")
            ),
            ["STILL_STEAM_CEF_RAW_ANGLE": "1"]
        )
        XCTAssertEqual(
            SteamBootstrapper.launchEnvironment(
                for: bottle,
                executableURL: URL(filePath: "/tmp/steam/game.exe")
            ),
            [:]
        )
        XCTAssertEqual(
            SteamBootstrapper.launchEnvironment(
                for: Bottle(
                    name: "Steam",
                    prefixURL: URL(filePath: "/tmp/steam"),
                    graphicsBackend: .wineD3D
                ),
                executableURL: URL(filePath: "/tmp/steam/steam.exe")
            ),
            [:]
        )
    }
}
