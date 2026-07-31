import Foundation

public actor JSONBottleStore: BottleRepository {
    private struct StoreDocument: Codable {
        let schemaVersion: Int
        var bottles: [Bottle]
    }

    public let storeURL: URL
    public let prefixesURL: URL
    private let fileManager: FileManager

    public init(
        rootURL: URL = JSONBottleStore.defaultRootURL(),
        fileManager: FileManager = .default
    ) {
        self.storeURL = rootURL.appending(path: "bottles.json")
        self.prefixesURL = rootURL.appending(path: "Bottles", directoryHint: .isDirectory)
        self.fileManager = fileManager
    }

    public static func defaultRootURL() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(
            path: ProductIdentity.bundleIdentifier,
            directoryHint: .isDirectory
        )
    }

    public func bottles() throws -> [Bottle] {
        try readDocument().bottles.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func bottle(id: Bottle.ID) throws -> Bottle? {
        try readDocument().bottles.first { $0.id == id }
    }

    public func save(_ bottle: Bottle) throws {
        var document = try readDocument()
        if let index = document.bottles.firstIndex(where: { $0.id == bottle.id }) {
            document.bottles[index] = bottle
        } else {
            document.bottles.append(bottle)
        }
        try write(document)
    }

    public func create(
        name: String,
        engineID: String? = nil,
        graphicsBackend: GraphicsBackend = .wineD3D,
        windowsVersion: Bottle.WindowsVersion = .windows10
    ) throws -> Bottle {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw StillCoreError.invalidBottleName
        }

        let id = UUID()
        let bottle = Bottle(
            id: id,
            name: trimmedName,
            prefixURL: prefixesURL.appending(path: id.uuidString, directoryHint: .isDirectory),
            engineID: engineID,
            graphicsBackend: graphicsBackend,
            windowsVersion: windowsVersion
        )
        try save(bottle)
        return bottle
    }

    private func readDocument() throws -> StoreDocument {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return StoreDocument(
                schemaVersion: ProductIdentity.schemaVersion,
                bottles: []
            )
        }

        let data = try Data(contentsOf: storeURL)
        let document = try JSONDecoder.still.decode(StoreDocument.self, from: data)
        guard document.schemaVersion == ProductIdentity.schemaVersion else {
            throw StillCoreError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    private func write(_ document: StoreDocument) throws {
        try fileManager.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.still.encode(document)
        try data.write(to: storeURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var still: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let bitPattern = date.timeIntervalSinceReferenceDate.bitPattern
            try container.encode(String(bitPattern, radix: 16))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var still: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let encoded = try container.decode(String.self)
            guard let bitPattern = UInt64(encoded, radix: 16) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "The encoded date is not a valid hexadecimal bit pattern."
                )
            }
            return Date(
                timeIntervalSinceReferenceDate: TimeInterval(bitPattern: bitPattern)
            )
        }
        return decoder
    }
}
