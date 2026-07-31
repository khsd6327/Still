import CryptoKit
import Foundation

public enum SHA256Verifier {
    public static func digest(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(fileURL: URL, expectedDigest: String) throws {
        let actualDigest = try digest(of: fileURL)
        guard actualDigest == expectedDigest.lowercased() else {
            throw StillCoreError.checksumMismatch(
                expected: expectedDigest.lowercased(),
                actual: actualDigest
            )
        }
    }
}
