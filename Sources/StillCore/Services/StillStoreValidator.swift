import Foundation

public struct StillStoreValidator: Sendable {
    public init() {}

    public func validate(_ document: StillStoreDocument) throws {
        try requireUnique(document.environments.map(\.id), label: "Environment")
        try requireUnique(document.applications.map(\.id), label: "Application")
        try requireUnique(document.launchEntries.map(\.id), label: "Launch Entry")
        try requireUnique(document.engineBuilds.map(\.id), label: "Engine Build")
        try requireUnique(document.components.map(\.id), label: "Component")
        try requireUnique(document.operations.map(\.id), label: "Operation")

        let environmentIDs = Set(document.environments.map(\.id))
        let applicationIDs = Set(document.applications.map(\.id))

        for application in document.applications {
            guard environmentIDs.contains(application.environmentID) else {
                throw StillCoreError.invalidStore(
                    "Application '\(application.id)' refers to missing Environment '\(application.environmentID)'."
                )
            }
            let storedEntryIDs = Set(
                document.launchEntries
                    .filter { $0.applicationID == application.id }
                    .map(\.id)
            )
            guard Set(application.launchEntryIDs) == storedEntryIDs,
                  application.launchEntryIDs.count == storedEntryIDs.count else {
                throw StillCoreError.invalidStore(
                    "Application '\(application.id)' has inconsistent Launch Entries."
                )
            }
        }

        for entry in document.launchEntries where !applicationIDs.contains(entry.applicationID) {
            throw StillCoreError.invalidStore(
                "Launch Entry '\(entry.id)' refers to missing Application '\(entry.applicationID)'."
            )
        }

        for operation in document.operations {
            guard environmentIDs.contains(operation.environmentID) else {
                throw StillCoreError.invalidStore(
                    "Operation '\(operation.id)' refers to missing Environment '\(operation.environmentID)'."
                )
            }
            if let applicationID = operation.applicationID,
               !applicationIDs.contains(applicationID) {
                throw StillCoreError.invalidStore(
                    "Operation '\(operation.id)' refers to missing Application '\(applicationID)'."
                )
            }
        }
    }

    private func requireUnique<ID: Hashable>(_ ids: [ID], label: String) throws {
        guard Set(ids).count == ids.count else {
            throw StillCoreError.invalidStore("Duplicate \(label) identifiers were found.")
        }
    }
}
