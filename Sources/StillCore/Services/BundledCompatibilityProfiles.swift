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

    public static let all = [steam]
}
