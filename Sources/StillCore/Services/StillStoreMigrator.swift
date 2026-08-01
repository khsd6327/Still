import Foundation

public struct StillStoreMigrator: Sendable {
    private struct LegacyBottleDocument: Codable {
        let schemaVersion: Int
        let bottles: [Bottle]
    }

    private struct LegacyPin: Codable {
        let bottleID: Bottle.ID
        let application: InstalledWindowsApplication
    }

    private struct LegacyPinDocument: Codable {
        let schemaVersion: Int
        let pins: [LegacyPin]
    }

    public init() {}

    public func migrate(
        bottlesData: Data?,
        pinsData: Data?
    ) throws -> StillStoreDocument {
        let bottles = try decodeBottles(bottlesData)
        let pins = try decodePins(pinsData)
        let environmentIDs = Set(bottles.map(\.id))

        if let orphan = pins.first(where: { !environmentIDs.contains($0.bottleID) }) {
            throw StillCoreError.invalidStore(
                "Pinned application '\(orphan.application.id)' refers to missing legacy bottle '\(orphan.bottleID)'."
            )
        }

        var applications: [LibraryApplication] = []
        var launchEntries: [LaunchEntry] = []

        for pin in pins {
            let applicationID = StableID.derived(
                from: "legacy-application:\(pin.bottleID.uuidString):\(pin.application.id)"
            )
            let launchEntryID = StableID.derived(
                from: "legacy-launch-entry:\(applicationID.uuidString):primary"
            )
            applications.append(
                LibraryApplication(
                    id: applicationID,
                    environmentID: pin.bottleID,
                    name: pin.application.name,
                    category: category(for: pin.application.source),
                    providerID: providerID(for: pin.application.source),
                    providerItemID: pin.application.sourceIdentifier,
                    launchEntryIDs: [launchEntryID]
                )
            )
            launchEntries.append(
                LaunchEntry(
                    id: launchEntryID,
                    applicationID: applicationID,
                    executableURL: pin.application.launcherURL,
                    arguments: pin.application.launchArguments,
                    workingDirectoryURL: pin.application.installDirectoryURL
                )
            )
        }

        return StillStoreDocument(
            environments: bottles.map(WindowsEnvironment.init(migrating:)),
            applications: applications.sorted { $0.id.uuidString < $1.id.uuidString },
            launchEntries: launchEntries.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    private func decodeBottles(_ data: Data?) throws -> [Bottle] {
        guard let data else { return [] }
        let document = try legacyBottleDecoder.decode(
            LegacyBottleDocument.self,
            from: data
        )
        guard document.schemaVersion == 1 else {
            throw StillCoreError.unsupportedSchema(document.schemaVersion)
        }
        return document.bottles
    }

    private func decodePins(_ data: Data?) throws -> [LegacyPin] {
        guard let data else { return [] }
        let document = try JSONDecoder().decode(LegacyPinDocument.self, from: data)
        guard document.schemaVersion == 1 else {
            throw StillCoreError.unsupportedApplicationPinSchema(
                document.schemaVersion
            )
        }
        return document.pins
    }

    private var legacyBottleDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let encoded = try container.decode(String.self)
            guard let bitPattern = UInt64(encoded, radix: 16) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid legacy date bit pattern."
                )
            }
            return Date(
                timeIntervalSinceReferenceDate: TimeInterval(
                    bitPattern: bitPattern
                )
            )
        }
        return decoder
    }

    private func category(
        for source: WindowsApplicationSource
    ) -> LibraryApplicationCategory {
        switch source {
        case .steam:
            .game
        case .office:
            .productivity
        case .standalone, .pinned:
            .application
        }
    }

    private func providerID(for source: WindowsApplicationSource) -> String? {
        source == .steam ? "steam" : nil
    }
}
