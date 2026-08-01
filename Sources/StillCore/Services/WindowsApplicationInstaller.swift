import Foundation

public actor WindowsApplicationInstaller {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func install(
        localInstallerURL: URL,
        recipe: WindowsApplicationRecipe,
        bottle: Bottle,
        engine: any WineEngine
    ) async throws -> LaunchSession {
        guard let requirements = recipe.installer else {
            throw StillCoreError.recipeInstallerUnavailable(recipe.id)
        }
        try validate(localInstallerURL, requirements: requirements)
        return try await engine.launch(
            LaunchRequest(
                bottle: bottle,
                executableURL: localInstallerURL,
                arguments: requirements.arguments
            )
        )
    }

    private func validate(
        _ url: URL,
        requirements: LocalInstallerRequirements
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw StillCoreError.invalidWindowsInstaller(url)
        }
        let name = url.lastPathComponent.lowercased()
        let fileExtension = url.pathExtension.lowercased()
        guard requirements.acceptedExtensions.contains(fileExtension),
              requirements.acceptedFileNames.isEmpty
                || requirements.acceptedFileNames.contains(name) else {
            throw StillCoreError.invalidWindowsInstaller(url)
        }
        if fileExtension == "exe" {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 2) == Data([0x4d, 0x5a]) else {
                throw StillCoreError.invalidWindowsInstaller(url)
            }
        }
    }
}
