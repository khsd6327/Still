import Foundation

public enum DependencyPlanStep: Codable, Hashable, Sendable {
    case installComponent(id: String, exactVersion: String)
}

public struct DependencyPlanner: Sendable {
    public init() {}

    public func plan(
        profile: CompatibilityProfile,
        installedComponents: [RuntimeComponent]
    ) -> [DependencyPlanStep] {
        profile.dependencies.compactMap { dependency in
            let isInstalled = installedComponents.contains {
                $0.id == dependency.componentID && $0.version == dependency.exactVersion
            }
            return isInstalled ? nil : .installComponent(
                id: dependency.componentID,
                exactVersion: dependency.exactVersion
            )
        }
    }
}
