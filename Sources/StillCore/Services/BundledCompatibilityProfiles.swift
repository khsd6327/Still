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
        requiredCapabilities: [.win64]
    )

    public static let all = [steam]
}
