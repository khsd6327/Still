import Foundation

public enum BundledEngineCatalog {
    public static let manifests: [EngineManifest] = [
        EngineManifest(
            id: "gcenx-wine-stable-11.0_1",
            family: .wineStable,
            displayName: "Wine Stable 11.0",
            version: "11.0_1",
            sourceURL: URL(string: "https://github.com/Gcenx/macOS_Wine_builds")!,
            downloadURL: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz")!,
            sha256: "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388",
            downloadSize: 185_303_032,
            archiveRoot: "Wine Stable.app",
            wineBinaryRelativePath: "Contents/Resources/wine/bin/wine",
            capabilities: [.win64, .wow64, .esync],
            requirements: [
                "macOS Catalina or later",
                "GStreamer.framework 1.28.1 installed for all users"
            ]
        ),
        EngineManifest(
            id: "gcenx-wine-devel-11.14",
            family: .wineDevel,
            displayName: "Wine Devel 11.14",
            version: "11.14",
            sourceURL: URL(string: "https://github.com/Gcenx/macOS_Wine_builds")!,
            downloadURL: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.14/wine-devel-11.14-osx64.tar.xz")!,
            sha256: "63ceb7633c0e477d2bd5b1057a38e539076d14678ded0f648706936492b5a400",
            downloadSize: 189_973_788,
            archiveRoot: "Wine Devel.app",
            wineBinaryRelativePath: "Contents/Resources/wine/bin/wine",
            capabilities: [.win64, .wow64, .esync],
            requirements: [
                "macOS Catalina or later",
                "GStreamer.framework 1.28.5 installed for all users"
            ]
        ),
        EngineManifest(
            id: "gcenx-wine-staging-11.14",
            family: .wineStaging,
            displayName: "Wine Staging 11.14",
            version: "11.14",
            sourceURL: URL(string: "https://github.com/Gcenx/macOS_Wine_builds")!,
            downloadURL: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.14/wine-staging-11.14-osx64.tar.xz")!,
            sha256: "cc8ff0f2f95e26e591d049092c16898f10718b7c74addfbf6498ad06ca3bab42",
            downloadSize: 192_256_088,
            archiveRoot: "Wine Staging.app",
            wineBinaryRelativePath: "Contents/Resources/wine/bin/wine",
            capabilities: [.win64, .wow64, .esync],
            requirements: [
                "macOS Catalina or later",
                "GStreamer.framework 1.28.5 installed for all users"
            ]
        ),
        EngineManifest(
            id: "gcenx-gptk-3.0-3",
            family: .gamePortingToolkit,
            displayName: "Game Porting Toolkit 3.0-3",
            version: "3.0-3",
            sourceURL: URL(string: "https://github.com/Gcenx/game-porting-toolkit")!,
            downloadURL: URL(string: "https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz")!,
            sha256: "d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e",
            downloadSize: 239_200_808,
            archiveRoot: "Game Porting Toolkit.app",
            wineBinaryRelativePath: "Contents/Resources/wine/bin/wine64",
            capabilities: [.win64, .wow64, .esync, .msync, .d3dMetal],
            requirements: [
                "Apple silicon",
                "macOS Sonoma 14 or later",
                "16 GB memory recommended"
            ],
            distributionPolicy: .externalLicenseRequired,
            licenseURL: URL(string: "https://github.com/Gcenx/game-porting-toolkit/releases/tag/Game-Porting-Toolkit-3.0-3")
        )
    ]

    public static func manifest(id: String) throws -> EngineManifest {
        guard let manifest = manifests.first(where: { $0.id == id }) else {
            throw StillCoreError.engineManifestNotFound(id)
        }
        return manifest
    }
}
