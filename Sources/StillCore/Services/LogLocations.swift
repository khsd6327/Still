import Foundation

public enum LogLocations {
    public static func defaultRootURL() -> URL {
        FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        )[0]
        .appending(path: "Logs", directoryHint: .isDirectory)
        .appending(path: ProductIdentity.bundleIdentifier, directoryHint: .isDirectory)
    }

    public static func launchLogURL(
        sessionID: UUID,
        rootURL: URL = defaultRootURL()
    ) -> URL {
        rootURL.appending(path: "\(sessionID.uuidString).log")
    }
}

