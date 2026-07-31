import Foundation

public actor BottleProvisioner {
    private let bottleStore: JSONBottleStore
    private let fileManager: FileManager

    public init(
        bottleStore: JSONBottleStore,
        fileManager: FileManager = .default
    ) {
        self.bottleStore = bottleStore
        self.fileManager = fileManager
    }

    public func create(
        name: String,
        engine: any WineEngine,
        recipeID: String? = nil,
        graphicsBackend: GraphicsBackend = .wineD3D,
        windowsVersion: Bottle.WindowsVersion = .windows10
    ) async throws -> Bottle {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw StillCoreError.invalidBottleName
        }

        let id = UUID()
        let prefixURL = bottleStore.prefixesURL
            .appending(path: id.uuidString, directoryHint: .isDirectory)
        let bottle = Bottle(
            id: id,
            name: trimmedName,
            prefixURL: prefixURL,
            engineID: engine.descriptor.id,
            recipeID: recipeID,
            graphicsBackend: graphicsBackend,
            windowsVersion: windowsVersion
        )

        do {
            try await engine.prepare(bottle)
            try await bottleStore.save(bottle)
            return bottle
        } catch {
            if fileManager.fileExists(atPath: prefixURL.path) {
                try? fileManager.removeItem(at: prefixURL)
            }
            throw error
        }
    }
}
