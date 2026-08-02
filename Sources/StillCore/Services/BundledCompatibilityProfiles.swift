import Foundation

public enum BundledCompatibilityProfiles {
    public static let steam = CompatibilityProfile(
        id: "valve-steam-preview",
        displayName: "Steam Client (Preview)",
        matchRules: [
            ProfileMatchRule(
                providerID: "steam",
                providerItemID: "client",
                executableNames: ["steam.exe"]
            )
        ],
        requiredEngineFamily: .wineStaging,
        requiredCapabilities: [.win64, .dxmt, .dxmtBridge],
        recommendedSettings: CompatibilitySettings(
            windowsVersion: .windows10,
            graphicsBackend: .dxmt,
            enhancedSync: .automatic
        ),
        validationEvidence: ["Steam client UI rendered with the pinned DXMT bridge build."]
    )

    public static let cashCleanerSimulator = CompatibilityProfile(
        id: "steam-2488370-dxmt",
        displayName: "Cash Cleaner Simulator",
        matchRules: [
            ProfileMatchRule(
                providerID: "steam",
                providerItemID: "2488370",
                executableNames: ["steam.exe"]
            )
        ],
        requiredEngineFamily: .wineStaging,
        requiredCapabilities: [.win64, .dxmt, .dxmtBridge],
        recommendedSettings: CompatibilitySettings(
            windowsVersion: .windows10,
            graphicsBackend: .dxmt,
            enhancedSync: .automatic,
            launchArguments: [
                "-dx11",
                "-ResX=1920",
                "-ResY=1080",
                "-NoVSync"
            ]
        )
    )

    public static let supermarketChaos = CompatibilityProfile(
        id: "steam-4800590-dxmt",
        displayName: "Supermarket Chaos",
        matchRules: [
            ProfileMatchRule(
                providerID: "steam",
                providerItemID: "4800590",
                executableNames: ["steam.exe"]
            )
        ],
        requiredEngineFamily: .wineStaging,
        requiredCapabilities: [.win64, .dxmt, .dxmtBridge],
        recommendedSettings: CompatibilitySettings(
            windowsVersion: .windows10,
            graphicsBackend: .dxmt,
            enhancedSync: .automatic,
            launchArguments: [
                "-force-d3d11",
                "-force-d3d11-no-singlethreaded",
                "-screen-width", "1920",
                "-screen-height", "1080",
                "-screen-fullscreen", "1"
            ]
        )
    )

    public static let all = [steam, cashCleanerSimulator, supermarketChaos]
}
