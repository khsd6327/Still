import Foundation

public struct HostProcessSnapshot: Equatable, Sendable {
    public let processIdentifier: Int32
    public let parentProcessIdentifier: Int32
    public let residentMemoryKilobytes: UInt64
    public let cpuPercent: Double
    public let elapsedSeconds: TimeInterval
    public let command: String
    public let startedAt: Date?
    public let workingDirectoryPath: String?

    public init(
        processIdentifier: Int32,
        parentProcessIdentifier: Int32 = 0,
        residentMemoryKilobytes: UInt64,
        cpuPercent: Double,
        elapsedSeconds: TimeInterval,
        command: String,
        startedAt: Date? = nil,
        workingDirectoryPath: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.parentProcessIdentifier = parentProcessIdentifier
        self.residentMemoryKilobytes = residentMemoryKilobytes
        self.cpuPercent = cpuPercent
        self.elapsedSeconds = elapsedSeconds
        self.command = command
        self.startedAt = startedAt
        self.workingDirectoryPath = workingDirectoryPath
    }

    public var identity: HostProcessIdentity {
        HostProcessIdentity(
            processIdentifier: processIdentifier,
            startedAt: startedAt
        )
    }
}

public struct HostProcessIdentity: Equatable, Hashable, Sendable {
    public let processIdentifier: Int32
    public let startedAt: Date?

    public init(processIdentifier: Int32, startedAt: Date?) {
        self.processIdentifier = processIdentifier
        self.startedAt = startedAt
    }

    public func matches(_ snapshot: HostProcessSnapshot, tolerance: TimeInterval = 2) -> Bool {
        guard processIdentifier == snapshot.processIdentifier else { return false }
        guard let startedAt, let candidateStartedAt = snapshot.startedAt else { return true }
        return abs(startedAt.timeIntervalSince(candidateStartedAt)) <= tolerance
    }
}

public struct LiveWineApplicationObservation: Equatable, Sendable {
    public let applicationID: LibraryApplication.ID
    public let environmentID: WindowsEnvironment.ID
    public let processIdentifier: Int32
    public let processName: String
    public let processIdentity: HostProcessIdentity
    public let relatedProcessIdentities: [HostProcessIdentity]

    public init(
        applicationID: LibraryApplication.ID,
        environmentID: WindowsEnvironment.ID,
        processIdentifier: Int32,
        processName: String,
        processIdentity: HostProcessIdentity? = nil,
        relatedProcessIdentities: [HostProcessIdentity] = []
    ) {
        self.applicationID = applicationID
        self.environmentID = environmentID
        self.processIdentifier = processIdentifier
        self.processName = processName
        self.processIdentity = processIdentity ?? HostProcessIdentity(
            processIdentifier: processIdentifier,
            startedAt: nil
        )
        self.relatedProcessIdentities = relatedProcessIdentities.isEmpty
            ? [self.processIdentity]
            : relatedProcessIdentities
    }
}

public enum WineProcessAttributionSource: Equatable, Sendable {
    case exactWinePrefixEnvironment
    case workingDirectoryFallback
}

public enum WineRuntimeProbe {
    public static func runningProcesses(
        enrichWorkingDirectories: Bool = true
    ) throws -> [HostProcessSnapshot] {
        let snapshots = try processSnapshots()
        guard enrichWorkingDirectories else { return snapshots }
        let wineProcessIDs = snapshots.compactMap { snapshot -> Int32? in
            looksLikeWindowsHostProcess(snapshot.command)
                ? snapshot.processIdentifier
                : nil
        }
        let workingDirectories = (try? currentWorkingDirectories(
            processIdentifiers: wineProcessIDs
        )) ?? [:]
        guard !workingDirectories.isEmpty else { return snapshots }
        let validationSnapshots = try processSnapshots()
        let validationByPID = Dictionary(
            uniqueKeysWithValues: validationSnapshots.map { ($0.processIdentifier, $0) }
        )
        return snapshots.map { snapshot in
            let stableWorkingDirectory: String?
            if let workingDirectory = workingDirectories[snapshot.processIdentifier],
               let validation = validationByPID[snapshot.processIdentifier],
               hasStableIdentity(snapshot, validation) {
                stableWorkingDirectory = workingDirectory
            } else {
                stableWorkingDirectory = nil
            }
            return HostProcessSnapshot(
                processIdentifier: snapshot.processIdentifier,
                parentProcessIdentifier: snapshot.parentProcessIdentifier,
                residentMemoryKilobytes: snapshot.residentMemoryKilobytes,
                cpuPercent: snapshot.cpuPercent,
                elapsedSeconds: snapshot.elapsedSeconds,
                command: snapshot.command,
                startedAt: snapshot.startedAt,
                workingDirectoryPath: stableWorkingDirectory
            )
        }
    }

    private static func processSnapshots() throws -> [HostProcessSnapshot] {
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
        return parseProcessList(
            String(decoding: data, as: UTF8.self),
            capturedAt: .now
        )
    }

    public static func parseProcessList(
        _ output: String,
        capturedAt: Date? = nil
    ) -> [HostProcessSnapshot] {
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
                command: String(fields[5]),
                startedAt: capturedAt?.addingTimeInterval(-elapsedSeconds)
            )
        }
    }

    public static func hasEnvironmentValue(
        _ key: String,
        value: String,
        in command: String
    ) -> Bool {
        let marker = "\(key)=\(value)"
        var searchStart = command.startIndex
        while let range = command.range(of: marker, range: searchStart..<command.endIndex) {
            let startsAtBoundary = range.lowerBound == command.startIndex
                || command[command.index(before: range.lowerBound)].isWhitespace
            let endsAtBoundary = range.upperBound == command.endIndex
                || command[range.upperBound].isWhitespace
            if startsAtBoundary && endsAtBoundary { return true }
            searchStart = range.upperBound
        }
        return false
    }

    public static func belongs(
        _ process: HostProcessSnapshot,
        to environment: WindowsEnvironment
    ) -> Bool {
        attribution(of: process, to: environment) != nil
    }

    public static func attribution(
        of process: HostProcessSnapshot,
        to environment: WindowsEnvironment
    ) -> WineProcessAttributionSource? {
        if hasEnvironmentValue(
            "WINEPREFIX",
            value: environment.prefixURL.standardizedFileURL.path,
            in: process.command
        ) {
            return .exactWinePrefixEnvironment
        }
        guard let workingDirectoryPath = process.workingDirectoryPath,
              path(
            workingDirectoryPath,
            isWithin: environment.prefixURL.standardizedFileURL.path
        ) else { return nil }
        return .workingDirectoryFallback
    }

    public static func attributedEnvironmentID(
        for process: HostProcessSnapshot,
        environments: [WindowsEnvironment]
    ) -> WindowsEnvironment.ID? {
        let exactMatches = environments.filter {
            attribution(of: process, to: $0) == .exactWinePrefixEnvironment
        }
        if exactMatches.count == 1 { return exactMatches[0].id }
        if exactMatches.count > 1 { return nil }

        let workingDirectoryMatches = environments.filter {
            attribution(of: process, to: $0) == .workingDirectoryFallback
        }
        guard let longestPathLength = workingDirectoryMatches
            .map({ $0.prefixURL.standardizedFileURL.path.count })
            .max() else { return nil }
        let longestMatches = workingDirectoryMatches.filter {
            $0.prefixURL.standardizedFileURL.path.count == longestPathLength
        }
        return longestMatches.count == 1 ? longestMatches[0].id : nil
    }

    static func parseCurrentWorkingDirectories(_ data: Data) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var processIdentifier: Int32?
        var isWorkingDirectory = false
        for rawField in data.split(separator: 0, omittingEmptySubsequences: true) {
            let field = rawField.drop(while: { $0 == 10 || $0 == 13 })
            guard let type = field.first else { continue }
            let value = field.dropFirst()
            switch type {
            case 112: // p
                processIdentifier = Int32(String(decoding: value, as: UTF8.self))
                isWorkingDirectory = false
            case 102: // f
                isWorkingDirectory = value.elementsEqual("cwd".utf8)
            case 110: // n
                if isWorkingDirectory, let processIdentifier {
                    result[processIdentifier] = String(decoding: value, as: UTF8.self)
                }
            default:
                continue
            }
        }
        return result
    }

    public static func orphanedMonitorProcesses(
        in processes: [HostProcessSnapshot],
        environments: [WindowsEnvironment]
    ) -> [HostProcessSnapshot] {
        processes.filter { process in
            guard process.parentProcessIdentifier == 1,
                  process.command.contains("wineserver -w"),
                  process.command.contains("STILL_MONITOR_TOKEN=") else {
                return false
            }
            return environments.contains { belongs(process, to: $0) }
        }
    }

    public static func orphanedMonitorProcessIdentifiers(
        in processes: [HostProcessSnapshot],
        environments: [WindowsEnvironment]
    ) -> [Int32] {
        orphanedMonitorProcesses(in: processes, environments: environments)
            .map(\.processIdentifier)
    }

    public static func liveEnvironmentIDs(
        in processes: [HostProcessSnapshot],
        environments: [WindowsEnvironment]
    ) -> Set<WindowsEnvironment.ID> {
        Set(environments.compactMap { environment in
            return processes.contains {
                attributedEnvironmentID(for: $0, environments: environments) == environment.id
                    && $0.command.localizedCaseInsensitiveContains("wineserver")
            } ? environment.id : nil
        })
    }

    public static func requireStopped(
        environmentID: WindowsEnvironment.ID,
        environments: [WindowsEnvironment],
        processes: [HostProcessSnapshot],
        sessions: [LaunchSession]
    ) throws {
        guard !sessions.contains(where: {
            $0.environmentID == environmentID && $0.state.isActive
        }),
        !liveEnvironmentIDs(
            in: processes,
            environments: environments.filter { $0.id == environmentID }
        ).contains(environmentID) else {
            throw StillCoreError.environmentMustBeStopped(environmentID)
        }
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
                guard attributedEnvironmentID(
                    for: process,
                    environments: environments
                ) == environment.id else { return false }
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
            let identities = matches
                .map(\.identity)
                .sorted { $0.processIdentifier < $1.processIdentifier }
            return LiveWineApplicationObservation(
                applicationID: application.id,
                environmentID: application.environmentID,
                processIdentifier: process.processIdentifier,
                processName: entry.executableURL.lastPathComponent,
                processIdentity: process.identity,
                relatedProcessIdentities: identities
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
            guard attributedEnvironmentID(
                for: process,
                environments: [environment]
            ) == environment.id else { return false }
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

    private static func currentWorkingDirectories(
        processIdentifiers: [Int32]
    ) throws -> [Int32: String] {
        guard !processIdentifiers.isEmpty else { return [:] }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/sbin/lsof")
        process.arguments = [
            "-a",
            "-p",
            processIdentifiers.map(String.init).joined(separator: ","),
            "-d",
            "cwd",
            "-F0pfn",
            "-w"
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseCurrentWorkingDirectories(data)
    }

    private static func path(_ candidate: String, isWithin root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func looksLikeWindowsHostProcess(_ command: String) -> Bool {
        let lowercased = command.lowercased()
        guard lowercased.contains(".exe") else { return false }
        return lowercased.contains("\\") || lowercased.contains("/wine")
    }

    private static func hasStableIdentity(
        _ original: HostProcessSnapshot,
        _ validation: HostProcessSnapshot
    ) -> Bool {
        guard original.processIdentifier == validation.processIdentifier,
              let originalStart = original.startedAt,
              let validationStart = validation.startedAt else {
            return false
        }
        return abs(originalStart.timeIntervalSince(validationStart)) <= 1
    }
}
