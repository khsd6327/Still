import Foundation

public struct CompatibilityProfileMatcher: Sendable {
    public init() {}

    public func profile(
        for application: LibraryApplication,
        executableURL: URL,
        profiles: [CompatibilityProfile]
    ) -> CompatibilityProfile? {
        if let selectedID = application.selectedProfileID,
           let selected = profiles.first(where: { $0.id == selectedID }),
           matches(selected, application: application, executableURL: executableURL) {
            return selected
        }
        return profiles.first {
            matches($0, application: application, executableURL: executableURL)
        }
    }

    public func matches(
        _ profile: CompatibilityProfile,
        application: LibraryApplication,
        executableURL: URL
    ) -> Bool {
        guard !profile.matchRules.isEmpty else { return false }
        let executableName = executableURL.lastPathComponent.lowercased()
        return profile.matchRules.contains { rule in
            if let providerID = rule.providerID,
               application.providerID?.caseInsensitiveCompare(providerID) != .orderedSame {
                return false
            }
            if let providerItemID = rule.providerItemID,
               application.providerItemID != providerItemID {
                return false
            }
            if !rule.executableNames.isEmpty,
               !rule.executableNames.contains(where: {
                   $0.caseInsensitiveCompare(executableName) == .orderedSame
               }) {
                return false
            }
            return true
        }
    }
}
