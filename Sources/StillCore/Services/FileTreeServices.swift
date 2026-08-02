import CryptoKit
import Darwin
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
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let relative = try relativePath(of: url, under: rootURL)
            if excluding(relative) {
                enumerator.skipDescendants()
                continue
            }
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
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw StillCoreError.invalidStore(
                "The copy destination already exists: \(destination.path)"
            )
        }
        do {
            let sourceEntries = try entries(at: source)
            let usedClone = try cloneCopy(from: source, to: destination)
            let destinationEntries = try entries(at: destination)
            guard sourceEntries == destinationEntries else {
                throw StillCoreError.verificationFailed(
                    "The copied Environment does not match its source."
                )
            }
            return usedClone
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
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
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return false
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
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

    static func lexicalRelativePath(of url: URL, under rootURL: URL) throws -> String {
        let filePath = url.standardizedFileURL.path
        let rootPaths = Set([
            rootURL.standardizedFileURL.path,
            canonicalExistingPath(rootURL)
        ])
        for rootPath in rootPaths {
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if filePath.hasPrefix(prefix) {
                return String(filePath.dropFirst(prefix.count))
            }
        }
        throw StillCoreError.unsafeArchivePath(filePath)
    }

    private static func canonicalExistingPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = url.withUnsafeFileSystemRepresentation { pointer -> String? in
            guard let pointer, realpath(pointer, &buffer) != nil else { return nil }
            let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
            return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
        return resolved ?? url.standardizedFileURL.path
    }
}
