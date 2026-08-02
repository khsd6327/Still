import Foundation

public struct HostProcessSnapshot: Equatable, Sendable {
    public let processIdentifier: Int32
    public let parentProcessIdentifier: Int32
    public let residentMemoryKilobytes: UInt64
    public let cpuPercent: Double
    public let elapsedSeconds: TimeInterval
    public let command: String

    public init(
        processIdentifier: Int32,
        parentProcessIdentifier: Int32 = 0,
        residentMemoryKilobytes: UInt64,
        cpuPercent: Double,
        elapsedSeconds: TimeInterval,
        command: String
    ) {
        self.processIdentifier = processIdentifier
        self.parentProcessIdentifier = parentProcessIdentifier
        self.residentMemoryKilobytes = residentMemoryKilobytes
        self.cpuPercent = cpuPercent
        self.elapsedSeconds = elapsedSeconds
        self.command = command
    }
}

public struct LiveWineApplicationObservation: Equatable, Sendable {
    public let applicationID: LibraryApplication.ID
    public let environmentID: WindowsEnvironment.ID
    public let processIdentifier: Int32
    public let processName: String

    public init(
        applicationID: LibraryApplication.ID,
        environmentID: WindowsEnvironment.ID,
        processIdentifier: Int32,
        processName: String
    ) {
        self.applicationID = applicationID
        self.environmentID = environmentID
        self.processIdentifier = processIdentifier
        self.processName = processName
    }
}

public enum WineRuntimeProbe {
    public static func runningProcesses() throws -> [HostProcessSnapshot] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["eww", "-axo", "pid=,ppid=,rss=,%cpu=,etime=,command="]
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

    public static func parseProcessList(_ output: String) -> [HostProcessSnapshot] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(
                maxSplits: 5,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 6,
                  let processIdentifier = Int32(fields[0]),
                  let parentProcessIdentifier = Int32(fields[1]),
                  let residentMemoryKilobytes = UInt64(fields[2]),
                  let cpuPercent = Double(fields[3]),
                  let elapsedSeconds = parseElapsed(String(fields[4])) else {
                return nil
            }
            return HostProcessSnapshot(
                processIdentifier: processIdentifier,
                parentProcessIdentifier: parentProcessIdentifier,
                residentMemoryKilobytes: residentMemoryKilobytes,
                cpuPercent: cpuPercent,
                elapsedSeconds: elapsedSeconds,
                command: String(fields[5])
            )
        }
    }

    public static func orphanedMonitorProcessIdentifiers(
        in processes: [HostProcessSnapshot],
        environments: [WindowsEnvironment]
    ) -> [Int32] {
        let prefixMarkers = environments.map {
            "WINEPREFIX=\($0.prefixURL.standardizedFileURL.path)"
        }
        return processes.compactMap { process in
            guard process.parentProcessIdentifier == 1,
                  process.command.contains("wineserver -w"),
                  prefixMarkers.contains(where: process.command.contains) else {
                return nil
            }
            return process.processIdentifier
        }
    }

    public static func liveEnvironmentIDs(
        in processes: [HostProcessSnapshot],
        environments: [WindowsEnvironment]
    ) -> Set<WindowsEnvironment.ID> {
        Set(environments.compactMap { environment in
            let prefixMarker = "WINEPREFIX=\(environment.prefixURL.standardizedFileURL.path)"
            return processes.contains {
                $0.command.contains(prefixMarker)
                    && $0.command.localizedCaseInsensitiveContains("wineserver")
            } ? environment.id : nil
        })
    }

    public static func observeApplications(
        in processes: [HostProcessSnapshot],
        environments: [WindowsEnvironment],
        applications: [LibraryApplication],
        launchEntries: [LaunchEntry]
    ) -> [LiveWineApplicationObservation] {
        let liveEnvironmentIDs = liveEnvironmentIDs(
            in: processes,
            environments: environments
        )
        return applications.compactMap { application in
            guard liveEnvironmentIDs.contains(application.environmentID),
                  let environment = environments.first(where: {
                      $0.id == application.environmentID
                  }),
                  let entryID = application.launchEntryIDs.first,
                  let entry = launchEntries.first(where: { $0.id == entryID }) else {
                return nil
            }
            let executableName = entry.executableURL.lastPathComponent.lowercased()
            guard !executableName.isEmpty else { return nil }
            let executableDirectory = entry.executableURL
                .deletingLastPathComponent()
                .standardizedFileURL
            let workingDirectory = entry.workingDirectoryURL?.standardizedFileURL
            let usesLauncher = workingDirectory.map { $0 != executableDirectory } == true
            let workingDirectoryPrefix = workingDirectory.flatMap {
                WineCommandBuilder.windowsDirectoryPrefix(
                    $0,
                    prefixURL: environment.prefixURL
                )
            }
            let matches = processes.filter { process in
                let command = process.command.lowercased()
                let identifiesApplication = if usesLauncher,
                                               let workingDirectoryPrefix {
                    command.contains(workingDirectoryPrefix.lowercased())
                } else {
                    command.contains(executableName)
                }
                return identifiesApplication
                    && !command.contains("wine start")
                    && !command.contains("wineserver")
            }
            guard let process = matches.min(by: {
                $0.processIdentifier < $1.processIdentifier
            }) else { return nil }
            return LiveWineApplicationObservation(
                applicationID: application.id,
                environmentID: application.environmentID,
                processIdentifier: process.processIdentifier,
                processName: entry.executableURL.lastPathComponent
            )
        }
    }

    public static func performanceSnapshot(
        application: LibraryApplication,
        environment: WindowsEnvironment,
        entry: LaunchEntry,
        processes: [HostProcessSnapshot],
        launchLatency: TimeInterval?
    ) -> RuntimePerformanceSnapshot {
        let windowsPrefix = WineCommandBuilder.windowsDirectoryPrefix(
            entry.workingDirectoryURL ?? entry.executableURL.deletingLastPathComponent(),
            prefixURL: environment.prefixURL
        )
        let executableName = entry.executableURL.lastPathComponent.lowercased()
        let matches = processes.filter { process in
            if let windowsPrefix,
               process.command.localizedCaseInsensitiveContains(windowsPrefix) {
                return true
            }
            return process.command.lowercased().contains(executableName)
        }
        return RuntimePerformanceSnapshot(
            applicationID: application.id,
            environmentID: environment.id,
            launchLatency: launchLatency,
            processCount: matches.count,
            cpuPercent: matches.reduce(0) { $0 + $1.cpuPercent },
            residentMemoryBytes: matches.reduce(0) {
                $0 + ($1.residentMemoryKilobytes * 1_024)
            },
            graphicsBackend: environment.graphicsBackend,
            engineBuildID: environment.pinnedEngineBuildID,
            metalHUDEnabled: environment.metalHUDEnabled
        )
    }

    private static func parseElapsed(_ value: String) -> TimeInterval? {
        let dayParts = value.split(separator: "-", maxSplits: 1)
        let days: Double
        let clock: Substring
        if dayParts.count == 2 {
            guard let parsedDays = Double(dayParts[0]) else { return nil }
            days = parsedDays
            clock = dayParts[1]
        } else {
            days = 0
            clock = Substring(value)
        }
        let components = clock.split(separator: ":").compactMap { Double($0) }
        guard components.count == 2 || components.count == 3 else { return nil }
        let hours = components.count == 3 ? components[0] : 0
        let minutes = components.count == 3 ? components[1] : components[0]
        let seconds = components.count == 3 ? components[2] : components[1]
        return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    }
}
