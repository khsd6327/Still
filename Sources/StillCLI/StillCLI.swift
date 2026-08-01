import Foundation
import StillCore

@main
struct StillCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        let rootURL = rootURL(from: arguments)
        let store = JSONStillStore(rootURL: rootURL)
        let frozenLegacyMutations: Set<String> = [
            "create", "setup-steam", "pin-app", "unpin-app", "set-engine"
        ]
        if frozenLegacyMutations.contains(command) {
            throw CLIError.legacyMutationFrozen(command)
        }

        switch command {
        case "info":
            print("\(ProductIdentity.name) schema \(ProductIdentity.schemaVersion)")
            print("Store: \(rootURL.path)")
        case "list":
            let environments = try await store.environments()
            if environments.isEmpty {
                print("No Environments.")
            } else {
                for environment in environments {
                    print(
                        "\(environment.id.uuidString)\t\(environment.name)"
                            + "\t\(environment.graphicsBackend.rawValue)"
                    )
                }
            }
        case "create", "setup-steam", "pin-app", "unpin-app", "set-engine":
            throw CLIError.legacyMutationFrozen(command)
        case "engines":
            let installer = EngineInstaller(rootURL: engineRootURL(from: arguments))
            let installedIDs = Set(
                await installer.installedDescriptors().map(\.id)
            )
            for manifest in BundledEngineCatalog.manifests {
                let status = installedIDs.contains(manifest.id)
                    ? "installed"
                    : "available"
                print(
                    "\(manifest.id)\t\(manifest.displayName)\t\(status)"
                )
            }
        case "install-engine":
            guard arguments.count >= 2 else {
                throw CLIError.missingEngineID
            }
            let manifest = try BundledEngineCatalog.manifest(id: arguments[1])
            let acceptsLicense = arguments.contains("--accept-license")
            let installer = EngineInstaller(rootURL: engineRootURL(from: arguments))
            let descriptor = try await installer.install(
                manifest,
                acceptsExternalLicense: acceptsLicense
            )
            print("Installed \(descriptor.displayName)")
            print("Wine: \(descriptor.wineBinaryURL.path)")
        case "install-engine-archive":
            guard arguments.count >= 3 else {
                throw CLIError.missingEngineArchive
            }
            let manifest = try BundledEngineCatalog.manifest(id: arguments[1])
            let archiveURL = URL(filePath: arguments[2])
            let installer = EngineInstaller(rootURL: engineRootURL(from: arguments))
            let descriptor = try await installer.installDownloadedArchive(
                manifest,
                archiveURL: archiveURL,
                acceptsExternalLicense: arguments.contains("--accept-license")
            )
            print("Installed \(descriptor.displayName)")
            print("Wine: \(descriptor.wineBinaryURL.path)")
        case "scan-apps":
            let environments = try await store.environments()
            let selected: [WindowsEnvironment]
            if arguments.count >= 2, !arguments[1].hasPrefix("--") {
                guard let environmentID = UUID(uuidString: arguments[1]),
                      let environment = environments.first(
                        where: { $0.id == environmentID }
                      ) else {
                    throw CLIError.environmentNotFound(arguments[1])
                }
                selected = [environment]
            } else {
                selected = environments
            }
            let coordinator = ApplicationDiscoveryCoordinator()
            for environment in selected {
                let result = coordinator.discover(in: bottle(from: environment))
                for candidate in result.accepted + result.requiresConfirmation {
                    let application = candidate.application
                    let disposition = candidate.requiresConfirmation ? "review" : "accepted"
                    print(
                        "\(environment.name)\t\(application.sourceIdentifier ?? "-")"
                            + "\t\(application.installState.rawValue)"
                            + "\t\(disposition)\t\(application.name)"
                    )
                }
                for providerID in result.providerFailures.keys.sorted() {
                    guard let failure = result.providerFailures[providerID] else { continue }
                    FileHandle.standardError.write(
                        Data("warning: \(environment.name) \(providerID): \(failure)\n".utf8)
                    )
                }
            }
        case "help", "--help", "-h":
            printHelp()
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func engineRootURL(from arguments: [String]) -> URL {
        guard let index = arguments.firstIndex(of: "--engine-root"),
              arguments.indices.contains(index + 1) else {
            return EngineLocations.defaultRootURL()
        }
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }

    private static func rootURL(from arguments: [String]) -> URL {
        guard let index = arguments.firstIndex(of: "--root"),
              arguments.indices.contains(index + 1) else {
            return JSONStillStore.defaultRootURL()
        }
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }

    private static func bottle(from environment: WindowsEnvironment) -> Bottle {
        Bottle(
            id: environment.id,
            name: environment.name,
            prefixURL: environment.prefixURL,
            engineID: environment.pinnedEngineBuildID,
            provisionedEngineID: environment.provisionedEngineBuildID,
            recipeID: environment.profileID,
            graphicsBackend: environment.graphicsBackend,
            windowsVersion: environment.windowsVersion,
            enhancedSync: environment.enhancedSync,
            metalHUDEnabled: environment.metalHUDEnabled,
            metalTraceEnabled: environment.metalTraceEnabled,
            createdAt: environment.createdAt,
            updatedAt: environment.updatedAt
        )
    }

    private static func printHelp() {
        print(
            """
            Usage: still-cli <command> [arguments] [--root <path>]

              info                 Show build and storage information.
              list                 List Environments from the primary store.
              create <name>        Temporarily unavailable during store migration.
              engines              List public and installed engines.
              install-engine <id>  Download, verify, and install an engine.
              install-engine-archive <id> <path>
                                    Verify and install a local engine archive.
              setup-steam <local-exe>
                                    Temporarily unavailable during store migration.
              scan-apps [environment-id]
                                    Scan Windows apps without modifying the store.
              pin-app <environment-id> <exe-path> [name]
                                    Temporarily unavailable during store migration.
              unpin-app <environment-id> <application-id>
                                    Temporarily unavailable during store migration.
              set-engine <environment-id> <engine-id>
                                    Temporarily unavailable during store migration.
              help                 Show this help.

            Options:
              --root <path>         Override Still storage.
              --engine-root <path>  Override engine storage.
              --accept-license      Confirm an external engine license.
            """
        )
    }
}

private enum CLIError: LocalizedError {
    case missingBottleName
    case missingEngineID
    case missingEngineArchive
    case missingLocalInstaller
    case missingPinArguments
    case missingUnpinArguments
    case missingSetEngineArguments
    case legacyMutationFrozen(String)
    case environmentNotFound(String)
    case unknownCommand(String)

    var errorDescription: String? {
        switch self {
        case .missingBottleName:
            "The create command requires a bottle name."
        case .missingEngineID:
            "The install-engine command requires an engine ID."
        case .missingEngineArchive:
            "The install-engine-archive command requires an engine ID and archive path."
        case .missingLocalInstaller:
            "The setup-steam command requires a user-supplied local installer path."
        case .missingPinArguments:
            "The pin-app command requires a bottle ID and executable path."
        case .missingUnpinArguments:
            "The unpin-app command requires a bottle ID and application ID."
        case .missingSetEngineArguments:
            "The set-engine command requires a bottle ID and engine ID."
        case .legacyMutationFrozen(let command):
            "The '\(command)' command is temporarily read-only while Still migrates the CLI to its primary store. No data was changed."
        case .environmentNotFound(let value):
            "Environment '\(value)' was not found."
        case .unknownCommand(let command):
            "Unknown command '\(command)'."
        }
    }
}
