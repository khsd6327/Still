import Foundation

public struct SupportBundlePreviewEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let byteCount: Int
    public let summary: String

    public init(relativePath: String, byteCount: Int, summary: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.summary = summary
    }
}

public struct SupportBundleFile: Equatable, Sendable {
    public let relativePath: String
    public let data: Data
    public let summary: String

    public init(relativePath: String, data: Data, summary: String) {
        self.relativePath = relativePath
        self.data = data
        self.summary = summary
    }
}

public struct SupportBundleDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let generatedAt: Date
    public let files: [SupportBundleFile]

    public init(
        id: UUID = UUID(),
        generatedAt: Date = .now,
        files: [SupportBundleFile]
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.files = files.sorted { $0.relativePath < $1.relativePath }
    }

    public var previewEntries: [SupportBundlePreviewEntry] {
        files.map {
            SupportBundlePreviewEntry(
                relativePath: $0.relativePath,
                byteCount: $0.data.count,
                summary: $0.summary
            )
        }
    }

    public var totalByteCount: Int {
        files.reduce(0) { $0 + $1.data.count }
    }
}
