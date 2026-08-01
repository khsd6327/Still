import Foundation

public enum WineCommandBuilder {
    public static func launchPlan(
        sessionID: UUID = UUID(),
        engine: EngineDescriptor,
        request: LaunchRequest,
        logURL: URL
    ) -> ProcessPlan {
        ProcessPlan(
            sessionID: sessionID,
            applicationID: request.applicationID,
            environmentID: request.environmentID,
            executableURL: engine.wineBinaryURL,
            arguments: [
                "start",
                "/unix",
                request.executableURL.path
            ] + request.arguments,
            environment: wineEnvironment(
                bottle: request.bottle,
                engine: engine,
                overrides: request.environment
            ),
            workingDirectoryURL: request.workingDirectoryURL
                ?? request.executableURL.deletingLastPathComponent(),
            logURL: logURL
        )
    }

    public static func preparePlan(
        sessionID: UUID = UUID(),
        engine: EngineDescriptor,
        bottle: Bottle,
        logURL: URL
    ) -> ProcessPlan {
        ProcessPlan(
            sessionID: sessionID,
            executableURL: engine.wineBinaryURL,
            arguments: ["wineboot", "--init"],
            environment: wineEnvironment(bottle: bottle, engine: engine),
            workingDirectoryURL: bottle.prefixURL,
            logURL: logURL
        )
    }

    public static func stopPlan(
        sessionID: UUID = UUID(),
        engine: EngineDescriptor,
        bottle: Bottle,
        logURL: URL
    ) -> ProcessPlan {
        ProcessPlan(
            sessionID: sessionID,
            executableURL: engine.wineBinaryURL,
            arguments: ["wineboot", "--end-session"],
            environment: wineEnvironment(bottle: bottle, engine: engine),
            workingDirectoryURL: bottle.prefixURL,
            logURL: logURL
        )
    }

    public static func forceStopPlan(
        sessionID: UUID = UUID(),
        engine: EngineDescriptor,
        bottle: Bottle,
        logURL: URL
    ) -> ProcessPlan {
        ProcessPlan(
            sessionID: sessionID,
            executableURL: engine.wineBinaryURL
                .deletingLastPathComponent()
                .appending(path: "wineserver"),
            arguments: ["-k"],
            environment: wineEnvironment(bottle: bottle, engine: engine),
            workingDirectoryURL: bottle.prefixURL,
            logURL: logURL
        )
    }

    public static func utilityPlan(
        sessionID: UUID = UUID(),
        engine: EngineDescriptor,
        bottle: Bottle,
        arguments: [String],
        logURL: URL
    ) -> ProcessPlan {
        ProcessPlan(
            sessionID: sessionID,
            executableURL: engine.wineBinaryURL,
            arguments: arguments,
            environment: wineEnvironment(bottle: bottle, engine: engine),
            workingDirectoryURL: bottle.prefixURL,
            logURL: logURL
        )
    }

    static func wineEnvironment(
        bottle: Bottle,
        engine: EngineDescriptor,
        overrides: [String: String] = [:]
    ) -> [String: String] {
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        var environment = Dictionary(
            uniqueKeysWithValues: inheritedEnvironment.compactMap { key, value in
                Self.inheritedEnvironmentKeys.contains(key)
                    ? (key, value)
                    : nil
            }
        )
        environment["WINEPREFIX"] = bottle.prefixURL.path
        environment["WINEDEBUG"] = inheritedEnvironment["WINEDEBUG"]
            ?? "fixme-all"
        switch bottle.enhancedSync {
        case .automatic:
            if engine.capabilities.contains(.msync) {
                environment["WINEMSYNC"] = "1"
                environment["WINEESYNC"] = "1"
            } else if engine.capabilities.contains(.esync) {
                environment["WINEESYNC"] = "1"
            }
        case .none:
            break
        case .esync:
            if engine.capabilities.contains(.esync) {
                environment["WINEESYNC"] = "1"
            }
        case .msync:
            if engine.capabilities.contains(.msync) {
                environment["WINEMSYNC"] = "1"
                environment["WINEESYNC"] = "1"
            }
        }
        if bottle.metalHUDEnabled {
            environment["MTL_HUD_ENABLED"] = "1"
        }
        if bottle.metalTraceEnabled {
            environment["METAL_CAPTURE_ENABLED"] = "1"
        }
        if bottle.graphicsBackend == .dxmt {
            environment["WINEDLLOVERRIDES"] = "dxgi,d3d9,d3d10core,d3d11=b"
        }
        environment.merge(overrides, uniquingKeysWith: { _, replacement in replacement })
#if DEBUG
        if environment.removeValue(forKey: "STILL_ENABLE_DXMT_DIAGNOSTIC_SHIM") == "1",
           bottle.graphicsBackend == .dxmt {
            let bridgeURL = dxmtDiagnosticShimURL(for: engine)
            if FileManager.default.fileExists(atPath: bridgeURL.path) {
                environment["DYLD_INSERT_LIBRARIES"] = bridgeURL.path
            }
        }
#else
        environment.removeValue(forKey: "STILL_ENABLE_DXMT_DIAGNOSTIC_SHIM")
#endif
        return environment
    }

    static func dxmtDiagnosticShimURL(for engine: EngineDescriptor) -> URL {
        engine.wineBinaryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "lib/wine/x86_64-unix/libstill-dxmt-macdrv-bridge.dylib")
    }

    private static let inheritedEnvironmentKeys: Set<String> = [
        "DISPLAY",
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LOGNAME",
        "PATH",
        "SHELL",
        "TMPDIR",
        "USER"
    ]
}
