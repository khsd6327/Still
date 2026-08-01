import CryptoKit
import Foundation

struct FileTreeEntry: Hashable {
    let relativePath: String
    let byteCount: Int64
    let sha256: String
}

enum FileTreeServices {
    static func entries(
        at rootURL: URL,
        excluding: (String) -> Bool = { _ in false }
    ) throws -> [FileTreeEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [FileTreeEntry] = []
        for case let url as URL in enumerator {
            let relative = try relativePath(of: url, under: rootURL)
            if excluding(relative) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let data = try Data(contentsOf: url)
            result.append(FileTreeEntry(
                relativePath: relative,
                byteCount: Int64(values.fileSize ?? data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            ))
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    static func verifiedCopy(from source: URL, to destination: URL) throws -> Bool {
        let sourceEntries = try entries(at: source)
        let usedClone = try cloneCopy(from: source, to: destination)
        let destinationEntries = try entries(at: destination)
        guard sourceEntries == destinationEntries else {
            throw StillCoreError.verificationFailed(
                "The copied Environment does not match its source."
            )
        }
        return usedClone
    }

    private static func cloneCopy(from source: URL, to destination: URL) throws -> Bool {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(filePath: "/bin/cp")
        process.arguments = ["-cR", source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 { return true }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return false
    }

    static func directorySize(_ url: URL) throws -> Int64 {
        try entries(at: url).reduce(0) { $0 + $1.byteCount }
    }

    static func relativePath(of url: URL, under rootURL: URL) throws -> String {
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else {
            throw StillCoreError.unsafeArchivePath(filePath)
        }
        return String(filePath.dropFirst(prefix.count))
    }
}
