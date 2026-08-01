import Foundation

public enum BundledApplicationRecipes {
    public static let steam = WindowsApplicationRecipe(
        id: "valve-steam",
        displayName: "Steam",
        defaultBottleName: "Steam",
        preferredEngineFamily: .wineStaging,
        windowsVersion: .windows10,
        graphicsBackend: .wineD3D,
        installer: LocalInstallerRequirements(
            acceptedFileNames: ["steamsetup.exe"],
            arguments: ["/S"]
        ),
        supportStatus: "Uses Wine Staging for the current 64-bit Steam client."
    )

    public static let all = [steam]
}
