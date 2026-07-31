import Foundation

public actor EngineRegistry {
    private var engines: [String: any WineEngine] = [:]

    public init() {}

    public func register(_ engine: any WineEngine) throws {
        let id = engine.descriptor.id
        guard engines[id] == nil else {
            throw StillCoreError.duplicateEngineID(id)
        }
        engines[id] = engine
    }

    public func descriptors() -> [EngineDescriptor] {
        engines.values
            .map(\.descriptor)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func engine(id: String) throws -> any WineEngine {
        guard let engine = engines[id] else {
            throw StillCoreError.engineNotFound(id)
        }
        return engine
    }
}

