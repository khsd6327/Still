import Darwin
import Foundation

struct HostProcessRecord: Equatable, Sendable {
    let processIdentifier: Int32
    let command: String
}

enum HostProcessTerminator {
    static func terminateProcesses(
        matchingWindowsPathPrefix pathPrefix: String,
        force: Bool
    ) throws -> [Int32] {
        let records = try runningProcesses().filter { $0.command.contains(pathPrefix) }
        let signal = force ? SIGKILL : SIGTERM
        var signaled: [Int32] = []
        for record in records {
            if Darwin.kill(record.processIdentifier, signal) == 0 {
                signaled.append(record.processIdentifier)
            } else if errno != ESRCH {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
            }
        }
        return signaled
    }

    static func parseProcessList(_ output: String) -> [HostProcessRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.drop(while: \.isWhitespace)
            guard let separator = line.firstIndex(where: \.isWhitespace),
                  let processIdentifier = Int32(line[..<separator]) else {
                return nil
            }
            let command = line[separator...].drop(while: \.isWhitespace)
            guard !command.isEmpty else { return nil }
            return HostProcessRecord(
                processIdentifier: processIdentifier,
                command: String(command)
            )
        }
    }

    private static func runningProcesses() throws -> [HostProcessRecord] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw StillCoreError.processFailed(process.terminationStatus)
        }
        return parseProcessList(String(decoding: data, as: UTF8.self))
    }
}
