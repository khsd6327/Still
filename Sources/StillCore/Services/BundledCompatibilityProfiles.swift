import Foundation

public enum BundledCompatibilityProfiles {
    public static let verifiedDXMTRevision = "3525d41c71604ed07d796de5b58560e3cf6db944"

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
        requiredDXMTRevision: verifiedDXMTRevision,
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
        requiredDXMTRevision: verifiedDXMTRevision,
        requiredCapabilities: [.win64, .dxmt, .dxmtBridge],
        recommendedSettings: CompatibilitySettings(
            windowsVersion: .windows10,
            graphicsBackend: .dxmt,
            enhancedSync: .automatic
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
        requiredDXMTRevision: verifiedDXMTRevision,
        requiredCapabilities: [.win64, .dxmt, .dxmtBridge],
        recommendedSettings: CompatibilitySettings(
            windowsVersion: .windows10,
            graphicsBackend: .dxmt,
            enhancedSync: .automatic
        )
    )

    public static let all = [steam, cashCleanerSimulator, supermarketChaos]
}
