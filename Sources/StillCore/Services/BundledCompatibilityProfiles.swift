import Foundation

public enum BundledCompatibilityProfiles {
    public static let steam = CompatibilityProfile(
        id: "valve-steam-preview",
        displayName: "Steam (Preview)",
        matchRules: [
            ProfileMatchRule(
                providerID: "steam",
                executableNames: ["steam.exe"]
            )
        ],
        requiredEngineFamily: .wineStaging,
        requiredCapabilities: [.win64, .wineD3D],
        recommendedSettings: CompatibilitySettings(
            windowsVersion: .windows10,
            graphicsBackend: .wineD3D,
            enhancedSync: .automatic,
            launchArguments: ["-cef-disable-gpu", "-cef-disable-gpu-compositing"]
        ),
        validationEvidence: ["Bundled preview profile; validate against the pinned engine build."]
    )

    public static let all = [steam]
}
