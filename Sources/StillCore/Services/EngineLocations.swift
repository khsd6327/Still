import Foundation

public enum EngineLocations {
    public static func defaultRootURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appending(path: ProductIdentity.bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Engines", directoryHint: .isDirectory)
    }
}
