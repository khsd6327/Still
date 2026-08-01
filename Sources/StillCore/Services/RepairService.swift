import Foundation

public struct RepairService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func inspect(
        environment: WindowsEnvironment,
        engineBuilds: [EngineBuild],
        components: [RuntimeComponent],
        profile: CompatibilityProfile?,
        launchEntries: [LaunchEntry]
    ) -> RepairReport {
        var issues: [RepairIssue] = []
        if !fileManager.fileExists(atPath: environment.prefixURL.path) {
            issues.append(RepairIssue(
                id: "missing-prefix",
                severity: .blocking,
                summary: "Environment files are missing.",
                proposedAction: .createPrefixDirectory
            ))
        }
        if let engineID = environment.pinnedEngineBuildID {
            if let engine = engineBuilds.first(where: { $0.id == engineID }) {
                if !fileManager.fileExists(atPath: engine.installURL.path) {
                    issues.append(RepairIssue(
                        id: "missing-engine-files",
                        severity: .blocking,
                        summary: "Pinned engine files are missing.",
                        proposedAction: .selectInstalledEngine
                    ))
                }
            } else {
                issues.append(RepairIssue(
                    id: "missing-engine-record",
                    severity: .blocking,
                    summary: "Pinned engine is not registered.",
                    proposedAction: .selectInstalledEngine
                ))
            }
        }
        for entry in launchEntries where !fileManager.fileExists(atPath: entry.executableURL.path) {
            issues.append(RepairIssue(
                id: "missing-launch-\(entry.id)",
                severity: .warning,
                summary: "A launch entry points to a missing executable.",
                proposedAction: .removeMissingLaunchEntry(entry.id)
            ))
        }
        if let profile {
            for dependency in profile.dependencies where !components.contains(where: {
                $0.id == dependency.componentID && $0.version == dependency.exactVersion
            }) {
                issues.append(RepairIssue(
                    id: "component-\(dependency.componentID)-\(dependency.exactVersion)",
                    severity: .blocking,
                    summary: "Required component \(dependency.componentID) \(dependency.exactVersion) is missing.",
                    proposedAction: .installComponent(
                        id: dependency.componentID,
                        exactVersion: dependency.exactVersion
                    )
                ))
            }
        }
        return RepairReport(environmentID: environment.id, inspectedAt: .now, issues: issues)
    }

    public func applyFileRepairs(
        _ actions: [TypedRepairAction],
        environment: WindowsEnvironment,
        launchEntries: [LaunchEntry],
        activeSessions: [LaunchSession],
        restorePointCreated: Bool
    ) throws -> [LaunchEntry] {
        guard !activeSessions.contains(where: {
            $0.environmentID == environment.id && $0.state.isActive
        }) else {
            throw StillCoreError.environmentMustBeStopped(environment.id)
        }
        guard restorePointCreated else {
            throw StillCoreError.engineChangeRequirementsNotMet(
                "Create a Restore Point before applying material repairs."
            )
        }
        var repairedEntries = launchEntries
        for action in actions {
            switch action {
            case .createPrefixDirectory:
                try fileManager.createDirectory(
                    at: environment.prefixURL,
                    withIntermediateDirectories: true
                )
            case .removeMissingLaunchEntry(let id):
                repairedEntries.removeAll { $0.id == id }
            case .selectInstalledEngine, .installComponent:
                throw StillCoreError.invalidCompatibilityConfiguration(
                    "This repair requires an explicit engine or component selection."
                )
            }
        }
        return repairedEntries
    }
}
