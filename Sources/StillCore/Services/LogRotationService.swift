import Foundation

public struct LogRotationService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    public func rotate(
        rootURL: URL = LogLocations.defaultRootURL(),
        retentionDays: Int,
        now: Date = .now
    ) throws -> [URL] {
        guard retentionDays >= 0 else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return [] }
        let cutoff = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -retentionDays,
            to: now
        ) ?? now
        var removed: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try fileManager.removeItem(at: url)
            removed.append(url)
        }
        return removed
    }
}
