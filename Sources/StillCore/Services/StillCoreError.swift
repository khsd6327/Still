import Foundation

public enum StillCoreError: LocalizedError, Equatable {
    case duplicateEngineID(String)
    case engineNotFound(String)
    case invalidBottleName
    case bottleNotFound(UUID)
    case unsupportedSchema(Int)
    case engineBinaryUnavailable(URL)
    case processFailed(Int32)
    case sessionNotFound(UUID)
    case engineManifestNotFound(String)
    case checksumMismatch(expected: String, actual: String)
    case invalidEngineArchive(String)
    case archiveExtractionFailed(String)
    case invalidEngineInstallation(URL)
    case externalLicenseAcceptanceRequired(String)
    case engineDownloadFailed(Int)
    case noInstalledEngine
    case invalidValveKeyValue(String)
    case untrustedInstallerURL(URL)
    case invalidWindowsInstaller(URL)
    case recipeInstallerUnavailable(String)
    case invalidApplicationState(String)
    case invalidPinnedApplication(URL)
    case unsupportedApplicationPinSchema(Int)
    case invalidCompatibilityConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateEngineID(let id):
            "An engine with ID '\(id)' is already registered."
        case .engineNotFound(let id):
            "Engine '\(id)' is not registered."
        case .invalidBottleName:
            "Bottle names must contain at least one non-whitespace character."
        case .bottleNotFound(let id):
            "Bottle '\(id)' was not found."
        case .unsupportedSchema(let version):
            "Bottle store schema \(version) is not supported."
        case .engineBinaryUnavailable(let url):
            "The Wine executable is missing or not executable: \(url.path)"
        case .processFailed(let exitCode):
            "The Wine process exited with status \(exitCode)."
        case .sessionNotFound(let id):
            "Launch session '\(id)' was not found."
        case .engineManifestNotFound(let id):
            "Engine manifest '\(id)' was not found."
        case .checksumMismatch(let expected, let actual):
            "Engine checksum mismatch. Expected \(expected), received \(actual)."
        case .invalidEngineArchive(let reason):
            "The engine archive is invalid. \(reason)"
        case .archiveExtractionFailed(let message):
            "The engine archive could not be extracted. \(message)"
        case .invalidEngineInstallation(let url):
            "The engine installation is incomplete: \(url.path)"
        case .externalLicenseAcceptanceRequired(let id):
            "Engine '\(id)' requires acceptance of its external license."
        case .engineDownloadFailed(let statusCode):
            "The engine download failed with HTTP status \(statusCode)."
        case .noInstalledEngine:
            "Install and select a Wine engine before creating a bottle."
        case .invalidValveKeyValue(let reason):
            "Valve metadata could not be parsed. \(reason)"
        case .untrustedInstallerURL(let url):
            "The installer URL is not trusted: \(url.absoluteString)"
        case .invalidWindowsInstaller(let url):
            "The downloaded file is not a valid Windows installer: \(url.path)"
        case .recipeInstallerUnavailable(let id):
            "Recipe '\(id)' does not have an automated installer."
        case .invalidApplicationState(let state):
            "The application cannot be launched while its state is '\(state)'."
        case .invalidPinnedApplication(let url):
            "Pinned applications must be existing .exe files inside the bottle: \(url.path)"
        case .unsupportedApplicationPinSchema(let version):
            "Application pin store schema \(version) is not supported."
        case .invalidCompatibilityConfiguration(let reason):
            "The bottle compatibility configuration is invalid. \(reason)"
        }
    }
}
