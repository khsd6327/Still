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
        let store = JSONBottleStore(rootURL: rootURL)

        switch command {
        case "info":
            print("\(ProductIdentity.name) schema \(ProductIdentity.schemaVersion)")
            print("Store: \(rootURL.path)")
        case "list":
            let bottles = try await store.bottles()
            if bottles.isEmpty {
                print("No bottles.")
            } else {
                for bottle in bottles {
                    print("\(bottle.id.uuidString)\t\(bottle.name)\t\(bottle.graphicsBackend.rawValue)")
                }
            }
        case "create":
            guard arguments.count >= 2 else {
                throw CLIError.missingBottleName
            }
            let bottle = try await store.create(name: arguments[1])
            print("Created \(bottle.name) at \(bottle.prefixURL.path)")
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
        case "setup-steam":
            let bootstrapper = SteamBootstrapper(
                bottleStore: store,
                engineInstaller: EngineInstaller(
                    rootURL: engineRootURL(from: arguments)
                )
            )
            let result = try await bootstrapper.bootstrap()
            print("Steam bottle: \(result.bottle.prefixURL.path)")
            if let executableURL = result.steamExecutableURL {
                print("Steam is installed: \(executableURL.path)")
            } else if let session = result.installerSession {
                print("Steam installer started (PID \(session.processIdentifier)).")
                print("Log: \(session.logURL?.path ?? "unavailable")")
            }
        case "scan-apps":
            let bottles = try await store.bottles()
            let selected: [Bottle]
            if arguments.count >= 2, !arguments[1].hasPrefix("--") {
                guard let bottleID = UUID(uuidString: arguments[1]),
                      let bottle = bottles.first(where: { $0.id == bottleID }) else {
                    throw CLIError.bottleNotFound(arguments[1])
                }
                selected = [bottle]
            } else {
                selected = bottles
            }
            let scanner = ApplicationLibraryScanner()
            let pinStore = JSONApplicationPinStore(rootURL: rootURL)
            for bottle in selected {
                var applications = Dictionary(
                    uniqueKeysWithValues: try scanner
                        .scan(bottle: bottle)
                        .map { ($0.id, $0) }
                )
                for application in try await pinStore.applications(
                    bottleID: bottle.id
                ) {
                    applications[application.id] = application
                }
                for application in applications.values.sorted(by: {
                    $0.name.localizedStandardCompare($1.name)
                        == .orderedAscending
                }) {
                    print(
                        "\(bottle.name)\t\(application.sourceIdentifier ?? "-")"
                            + "\t\(application.installState.rawValue)"
                            + "\t\(application.name)"
                    )
                }
            }
        case "pin-app":
            guard arguments.count >= 3 else {
                throw CLIError.missingPinArguments
            }
            guard let bottleID = UUID(uuidString: arguments[1]),
                  let bottle = try await store.bottle(id: bottleID) else {
                throw CLIError.bottleNotFound(arguments[1])
            }
            let executableURL = URL(filePath: arguments[2])
            let name = arguments.indices.contains(3)
                && !arguments[3].hasPrefix("--")
                ? arguments[3]
                : nil
            let application = try await JSONApplicationPinStore(
                rootURL: rootURL
            ).pin(
                executableURL: executableURL,
                name: name,
                in: bottle
            )
            print("Pinned \(application.name)")
            print("ID: \(application.id)")
        case "unpin-app":
            guard arguments.count >= 3,
                  let bottleID = UUID(uuidString: arguments[1]) else {
                throw CLIError.missingUnpinArguments
            }
            try await JSONApplicationPinStore(rootURL: rootURL).remove(
                applicationID: arguments[2],
                bottleID: bottleID
            )
            print("Removed pin \(arguments[2])")
        case "set-engine":
            guard arguments.count >= 3 else {
                throw CLIError.missingSetEngineArguments
            }
            guard let bottleID = UUID(uuidString: arguments[1]),
                  var bottle = try await store.bottle(id: bottleID) else {
                throw CLIError.bottleNotFound(arguments[1])
            }
            let engineID = arguments[2]
            let engineInstaller = EngineInstaller(
                rootURL: engineRootURL(from: arguments)
            )
            let installedIDs = Set(
                await engineInstaller.installedDescriptors().map(\.id)
            )
            guard installedIDs.contains(engineID) else {
                throw StillCoreError.engineNotFound(engineID)
            }
            bottle.engineID = engineID
            bottle.updatedAt = .now
            try await store.save(bottle)
            print("Changed \(bottle.name) engine to \(engineID)")
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
            return JSONBottleStore.defaultRootURL()
        }
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }

    private static func printHelp() {
        print(
            """
            Usage: still-cli <command> [arguments] [--root <path>]

              info                 Show build and storage information.
              list                 List bottles.
              create <name>        Create bottle metadata.
              engines              List public and installed engines.
              install-engine <id>  Download, verify, and install an engine.
              install-engine-archive <id> <path>
                                    Verify and install a local engine archive.
              setup-steam           Create a GPTK bottle and install Steam.
              scan-apps [bottle-id] Scan Windows apps in one or all bottles.
              pin-app <bottle-id> <exe-path> [name]
                                    Add a manual executable to the app library.
              unpin-app <bottle-id> <application-id>
                                    Remove a manual executable.
              set-engine <bottle-id> <engine-id>
                                    Change the Wine engine used by a bottle.
              help                 Show this help.

            Options:
              --root <path>         Override bottle storage.
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
    case missingPinArguments
    case missingUnpinArguments
    case missingSetEngineArguments
    case bottleNotFound(String)
    case unknownCommand(String)

    var errorDescription: String? {
        switch self {
        case .missingBottleName:
            "The create command requires a bottle name."
        case .missingEngineID:
            "The install-engine command requires an engine ID."
        case .missingEngineArchive:
            "The install-engine-archive command requires an engine ID and archive path."
        case .missingPinArguments:
            "The pin-app command requires a bottle ID and executable path."
        case .missingUnpinArguments:
            "The unpin-app command requires a bottle ID and application ID."
        case .missingSetEngineArguments:
            "The set-engine command requires a bottle ID and engine ID."
        case .bottleNotFound(let value):
            "Bottle '\(value)' was not found."
        case .unknownCommand(let command):
            "Unknown command '\(command)'."
        }
    }
}
