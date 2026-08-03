import Foundation

public struct SteamDiscoveryProvider: ApplicationDiscoveryProvider, @unchecked Sendable {
    public let id = "steam"
    public let removesMissingApplications = true
    private let scanner: SteamLibraryScanner
    private let fileManager: FileManager

    public init(
        scanner: SteamLibraryScanner = SteamLibraryScanner(),
        fileManager: FileManager = .default
    ) {
        self.scanner = scanner
        self.fileManager = fileManager
    }

    public func discover(in bottle: Bottle) throws -> ProviderDiscoveryResult {
        let scan = try scanner.scanResult(bottle: bottle)
        var candidates = scan.applications.map { application in
            DiscoveredApplicationCandidate(
                providerID: id,
                application: application,
                category: .game,
                confidence: .certain,
                requiresConfirmation: false,
                providerManagedState: application.installState
            )
        }
        let steamURL = steamExecutable(in: bottle)
        if let steamURL {
            candidates.append(DiscoveredApplicationCandidate(
                providerID: id,
                application: InstalledWindowsApplication(
                    id: "steam-client",
                    name: "Steam",
                    source: .steam,
                    sourceIdentifier: "client",
                    installState: .installed,
                    installDirectoryURL: steamURL.deletingLastPathComponent(),
                    launcherURL: steamURL,
                    launchArguments: SteamBootstrapper.launchArguments(for: bottle)
                ),
                category: .launcher,
                confidence: .certain,
                requiresConfirmation: false,
                providerManagedState: .installed
            ))
        }
        return ProviderDiscoveryResult(
            candidates: candidates,
            isComplete: scan.isComplete && steamURL != nil,
            warnings: scan.warnings
        )
    }

    private func steamExecutable(in bottle: Bottle) -> URL? {
        let candidates = [
            bottle.prefixURL.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe"),
            bottle.prefixURL.appending(path: "drive_c/Program Files/Steam/steam.exe")
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}

public struct ExecutableDiscoveryProvider: ApplicationDiscoveryProvider, @unchecked Sendable {
    public let id = "executable-fallback"
    private let scanner: WindowsExecutableScanner

    public init(scanner: WindowsExecutableScanner = WindowsExecutableScanner()) {
        self.scanner = scanner
    }

    public func discover(in bottle: Bottle) -> ProviderDiscoveryResult {
        ProviderDiscoveryResult(candidates: scanner.scan(bottle: bottle).map { application in
            let isOffice = application.source == .office
            let confidence: DiscoveryConfidence = isOffice ? .high : .medium
            return DiscoveredApplicationCandidate(
                providerID: id,
                application: application,
                category: isOffice ? .productivity : .application,
                confidence: confidence,
                requiresConfirmation: !isOffice
            )
        })
    }
}

public struct ApplicationDiscoveryCoordinator: Sendable {
    private let providers: [any ApplicationDiscoveryProvider]
    private let automaticThreshold: DiscoveryConfidence

    public init(
        providers: [any ApplicationDiscoveryProvider] = [
            SteamDiscoveryProvider(),
            ExecutableDiscoveryProvider()
        ],
        automaticThreshold: DiscoveryConfidence = .high
    ) {
        self.providers = providers
        self.automaticThreshold = automaticThreshold
    }

    public func discover(in bottle: Bottle) -> DiscoveryResult {
        let generation = UUID()
        var candidates: [String: DiscoveredApplicationCandidate] = [:]
        var failures: [String: String] = [:]
        var warnings: [String: [String]] = [:]
        var reconcilableProviderIDs: Set<String> = []
        for provider in providers {
            do {
                let result = try provider.discover(in: bottle)
                if !result.warnings.isEmpty {
                    warnings[provider.id] = result.warnings
                }
                if result.isComplete && provider.removesMissingApplications {
                    reconcilableProviderIDs.insert(provider.id)
                }
                for candidate in result.candidates {
                    let key = stableKey(candidate)
                    if let existing = candidates[key], existing.confidence >= candidate.confidence {
                        continue
                    }
                    candidates[key] = candidate
                }
            } catch {
                failures[provider.id] = error.localizedDescription
            }
        }
        let values = candidates.values.sorted {
            $0.application.name.localizedStandardCompare($1.application.name)
                == .orderedAscending
        }
        return DiscoveryResult(
            generation: generation,
            accepted: values.filter {
                !$0.requiresConfirmation && $0.confidence >= automaticThreshold
            },
            requiresConfirmation: values.filter {
                $0.requiresConfirmation || $0.confidence < automaticThreshold
            },
            providerFailures: failures,
            providerWarnings: warnings,
            reconcilableProviderIDs: reconcilableProviderIDs
        )
    }

    private func stableKey(_ candidate: DiscoveredApplicationCandidate) -> String {
        if let sourceIdentifier = candidate.application.sourceIdentifier {
            return "\(candidate.providerID):\(sourceIdentifier.lowercased())"
        }
        return candidate.application.launcherURL.standardizedFileURL.path.lowercased()
    }
}
