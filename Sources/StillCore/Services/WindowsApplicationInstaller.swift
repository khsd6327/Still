import Foundation

public actor WindowsApplicationInstaller {
    private let downloader: WindowsInstallerDownloader

    public init(
        downloader: WindowsInstallerDownloader = WindowsInstallerDownloader()
    ) {
        self.downloader = downloader
    }

    public func install(
        recipe: WindowsApplicationRecipe,
        bottle: Bottle,
        engine: any WineEngine
    ) async throws -> LaunchSession {
        guard let artifact = recipe.installer else {
            throw StillCoreError.recipeInstallerUnavailable(recipe.id)
        }
        let downloaded = try await downloader.download(
            recipeID: recipe.id,
            artifact: artifact
        )
        return try await engine.launch(
            LaunchRequest(
                bottle: bottle,
                executableURL: downloaded.fileURL,
                arguments: artifact.arguments
            )
        )
    }
}
