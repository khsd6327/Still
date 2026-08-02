import Foundation

public struct CompatibilityResolver: Sendable {
    public init() {}

    public func resolve(
        environment: WindowsEnvironment,
        profile: CompatibilityProfile? = nil,
        runtimePolicySettings: CompatibilitySettings = CompatibilitySettings(),
        runtimePolicyID: String = "runtime",
        applicationOverrides: CompatibilitySettings = CompatibilitySettings(),
        launchOverrides: CompatibilitySettings = CompatibilitySettings(),
        engineFamily: EngineFamily? = nil,
        engineDXMTRevision: String? = nil,
        registry: CapabilityRegistry
    ) throws -> EffectiveCompatibility {
        if let profile {
            if let requiredFamily = profile.requiredEngineFamily,
               engineFamily != requiredFamily {
                throw StillCoreError.invalidCompatibilityConfiguration(
                    "Profile '\(profile.id)' requires engine family '\(requiredFamily.rawValue)'."
                )
            }
            try registry.require(profile.requiredCapabilities)
            if let requiredRevision = profile.requiredDXMTRevision,
               engineDXMTRevision != requiredRevision {
                throw StillCoreError.invalidCompatibilityConfiguration(
                    "Profile '\(profile.id)' requires DXMT revision '\(requiredRevision)'."
                )
            }
        }

        var windowsVersion = SourcedValue(
            Bottle.WindowsVersion.windows10,
            source: .safeFallback
        )
        var graphicsBackend = SourcedValue(
            GraphicsBackend.wineD3D,
            source: .safeFallback
        )
        var enhancedSync = SourcedValue(
            EnhancedSyncMode.automatic,
            source: .safeFallback
        )
        var variables: [String: SourcedValue<String>] = [:]
        var arguments: [String] = []
        var argumentSource: CompatibilityValueSource = .safeFallback

        apply(
            CompatibilitySettings(
                windowsVersion: environment.windowsVersion,
                graphicsBackend: environment.graphicsBackend,
                enhancedSync: environment.enhancedSync
            ),
            source: .environment,
            windowsVersion: &windowsVersion,
            graphicsBackend: &graphicsBackend,
            enhancedSync: &enhancedSync,
            variables: &variables,
            arguments: &arguments,
            argumentSource: &argumentSource
        )
        if let profile {
            apply(
                profile.recommendedSettings,
                source: .profile(profile.id),
                windowsVersion: &windowsVersion,
                graphicsBackend: &graphicsBackend,
                enhancedSync: &enhancedSync,
                variables: &variables,
                arguments: &arguments,
                argumentSource: &argumentSource
            )
        }
        apply(
            runtimePolicySettings,
            source: .runtimePolicy(runtimePolicyID),
            windowsVersion: &windowsVersion,
            graphicsBackend: &graphicsBackend,
            enhancedSync: &enhancedSync,
            variables: &variables,
            arguments: &arguments,
            argumentSource: &argumentSource
        )
        apply(
            applicationOverrides,
            source: .applicationOverride,
            windowsVersion: &windowsVersion,
            graphicsBackend: &graphicsBackend,
            enhancedSync: &enhancedSync,
            variables: &variables,
            arguments: &arguments,
            argumentSource: &argumentSource
        )
        apply(
            launchOverrides,
            source: .launchOverride,
            windowsVersion: &windowsVersion,
            graphicsBackend: &graphicsBackend,
            enhancedSync: &enhancedSync,
            variables: &variables,
            arguments: &arguments,
            argumentSource: &argumentSource
        )

        try registry.require(registry.requiredCapabilities(for: graphicsBackend.value))
        try registry.require(registry.requiredCapabilities(for: enhancedSync.value))
        return EffectiveCompatibility(
            windowsVersion: windowsVersion,
            graphicsBackend: graphicsBackend,
            enhancedSync: enhancedSync,
            environmentVariables: variables,
            launchArguments: arguments,
            launchArgumentSource: argumentSource
        )
    }

    private func apply(
        _ settings: CompatibilitySettings,
        source: CompatibilityValueSource,
        windowsVersion: inout SourcedValue<Bottle.WindowsVersion>,
        graphicsBackend: inout SourcedValue<GraphicsBackend>,
        enhancedSync: inout SourcedValue<EnhancedSyncMode>,
        variables: inout [String: SourcedValue<String>],
        arguments: inout [String],
        argumentSource: inout CompatibilityValueSource
    ) {
        if let value = settings.windowsVersion {
            windowsVersion = SourcedValue(value, source: source)
        }
        if let value = settings.graphicsBackend {
            graphicsBackend = SourcedValue(value, source: source)
        }
        if let value = settings.enhancedSync {
            enhancedSync = SourcedValue(value, source: source)
        }
        for (key, value) in settings.environmentVariables {
            variables[key] = SourcedValue(value, source: source)
        }
        if !settings.launchArguments.isEmpty {
            arguments = settings.launchArguments
            argumentSource = source
        }
    }
}

public enum LaunchArgumentMerger {
    private struct Unit {
        let key: String?
        let tokens: [String]
    }

    private static let pairedOptions: Set<String> = [
        "-applaunch",
        "-screen-width",
        "-screen-height",
        "-screen-fullscreen",
        "-resx",
        "-resy"
    ]

    public static func merge(_ base: [String], _ additions: [String]) -> [String] {
        var units = parse(base)
        for addition in parse(additions) {
            if let key = addition.key {
                units.removeAll { $0.key == key }
            }
            units.append(addition)
        }
        return units.flatMap(\.tokens)
    }

    private static func parse(_ arguments: [String]) -> [Unit] {
        var result: [Unit] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard let key = optionKey(argument) else {
                result.append(Unit(key: nil, tokens: [argument]))
                index += 1
                continue
            }
            if pairedOptions.contains(key),
               !argument.contains("="),
               index + 1 < arguments.count {
                result.append(Unit(
                    key: key,
                    tokens: [argument, arguments[index + 1]]
                ))
                index += 2
            } else {
                result.append(Unit(key: key, tokens: [argument]))
                index += 1
            }
        }
        return result
    }

    private static func optionKey(_ argument: String) -> String? {
        guard argument.hasPrefix("-") || argument.hasPrefix("/") else { return nil }
        return String(argument.split(separator: "=", maxSplits: 1)[0]).lowercased()
    }
}
