import Foundation

public struct SteamBootstrapResult: Sendable {
    public let bottle: Bottle
    public let installerSession: LaunchSession?
    public let steamExecutableURL: URL?

    public init(
        bottle: Bottle,
        installerSession: LaunchSession?,
        steamExecutableURL: URL?
    ) {
        self.bottle = bottle
        self.installerSession = installerSession
        self.steamExecutableURL = steamExecutableURL
    }
}

public actor SteamBootstrapper {
    public static let softwareRenderingLaunchArguments = [
        "-cef-disable-gpu",
        "-cef-disable-gpu-compositing"
    ]

    // Steam's -cef-use-vulkan enables Chromium Vulkan compositor features in
    // addition to selecting ANGLE Vulkan. That combination is not supported by
    // the current DXMT configuration, so it must not be enabled by default.
    public static let dxmtLaunchArguments: [String] = []

    public static func launchArguments(for bottle: Bottle) -> [String] {
        switch bottle.graphicsBackend {
        case .dxmt:
            return dxmtLaunchArguments
        case .d3dMetal:
            return []
        case .wineD3D, .dxvk, .vkd3d:
            return softwareRenderingLaunchArguments
        }
    }

    public static func launchEnvironment(
        for bottle: Bottle,
        executableURL: URL
    ) -> [String: String] {
        guard bottle.graphicsBackend == .dxmt,
              executableURL.lastPathComponent.caseInsensitiveCompare("steam.exe")
                == .orderedSame else {
            return [:]
        }
        return ["STILL_STEAM_CEF_RAW_ANGLE": "1"]
    }

    private let bottleStore: JSONBottleStore
    private let engineInstaller: EngineInstaller
    private let applicationInstaller: WindowsApplicationInstaller
    private let fileManager: FileManager

    public init(
        bottleStore: JSONBottleStore = JSONBottleStore(),
        engineInstaller: EngineInstaller = EngineInstaller(),
        applicationInstaller: WindowsApplicationInstaller = WindowsApplicationInstaller(),
        fileManager: FileManager = .default
    ) {
        self.bottleStore = bottleStore
        self.engineInstaller = engineInstaller
        self.applicationInstaller = applicationInstaller
        self.fileManager = fileManager
    }

    public func bootstrap(localInstallerURL: URL? = nil) async throws -> SteamBootstrapResult {
        let recipe = BundledApplicationRecipes.steam
        let manifest = try preferredInstalledManifest(for: recipe)
        guard let descriptor = await engineInstaller.installedDescriptor(
            for: manifest
        ) else {
            throw StillCoreError.engineNotFound(manifest.id)
        }

        let bottles = try await bottleStore.bottles()
        let existingBottle = bottles.first {
            $0.recipeID == recipe.id
                && $0.provisionedEngineID == descriptor.id
        }
        let bottle: Bottle
        if let existingBottle {
            var reconciled = existingBottle
            if reconciled.engineID != descriptor.id
                || reconciled.graphicsBackend != recipe.graphicsBackend
                || reconciled.windowsVersion != recipe.windowsVersion {
                reconciled.engineID = descriptor.id
                reconciled.graphicsBackend = recipe.graphicsBackend
                reconciled.windowsVersion = recipe.windowsVersion
                reconciled.updatedAt = .now
                try await bottleStore.save(reconciled)
            }
            bottle = reconciled
        } else {
            let engine = LocalWineEngine(descriptor: descriptor)
            bottle = try await BottleProvisioner(
                bottleStore: bottleStore
            ).create(
                name: recipe.defaultBottleName,
                engine: engine,
                recipeID: recipe.id,
                graphicsBackend: recipe.graphicsBackend,
                windowsVersion: recipe.windowsVersion
            )
        }

        let steamExecutableURL = steamURL(in: bottle)
        if fileManager.fileExists(atPath: steamExecutableURL.path) {
            return SteamBootstrapResult(
                bottle: bottle,
                installerSession: nil,
                steamExecutableURL: steamExecutableURL
            )
        }

        guard let localInstallerURL else {
            throw StillCoreError.invalidWindowsInstaller(
                URL(filePath: "SteamSetup.exe")
            )
        }
        let engine = LocalWineEngine(descriptor: descriptor)
        let session = try await applicationInstaller.install(
            localInstallerURL: localInstallerURL,
            recipe: recipe,
            bottle: bottle,
            engine: engine
        )
        return SteamBootstrapResult(
            bottle: bottle,
            installerSession: session,
            steamExecutableURL: nil
        )
    }

    public func steamURL(in bottle: Bottle) -> URL {
        bottle.prefixURL.appending(
            path: "drive_c/Program Files (x86)/Steam/steam.exe"
        )
    }

    private func preferredInstalledManifest(
        for recipe: WindowsApplicationRecipe
    ) throws -> EngineManifest {
        let candidates = BundledEngineCatalog.manifests.filter {
            $0.family == recipe.preferredEngineFamily
        }
        guard let manifest = candidates.first else {
            throw StillCoreError.engineManifestNotFound(
                recipe.preferredEngineFamily.rawValue
            )
        }
        return manifest
    }
}
