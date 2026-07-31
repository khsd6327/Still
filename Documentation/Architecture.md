# Still architecture

## Design goals

1. Treat Wine builds as replaceable engines.
2. Keep graphics backends independent from Wine engine selection.
3. Store enough metadata to reproduce a bottle.
4. Never require the UI to construct shell commands.
5. Make process execution testable without launching Wine.
6. Keep import and migration adapters outside the core data model.

## Dependency direction

```text
StillDesktop ─┐
              ├──> StillCore
StillCLI ─────┘

StillCore models <- services <- platform adapters
```

`StillCore` must not import SwiftUI or AppKit.

## Primary concepts

### Bottle

A bottle describes a Wine prefix and the reproducible configuration used to run
applications inside it. The prefix itself remains ordinary Wine data.

### Engine

An engine is a versioned Wine installation. Engine identity is stored separately
from its local installation path so an engine can be reinstalled or relocated.

### Graphics backend

The graphics backend is selected per bottle. D3DMetal is represented as an
optional externally supplied backend and is not bundled by Still.

### Recipe

A recipe describes the preferred engine family, Windows version, graphics
backend, installer origin, and launch options for a specific application.
Recipes remain declarative and versioned. Only installable, testable recipes
belong in the bundled catalog.

## Implemented runtime path

`LocalWineEngine` converts a bottle operation into a `ProcessPlan` through
`WineCommandBuilder`. `ProcessSupervisor` starts the executable without a shell,
captures standard output and standard error in a per-session log, tracks the
process by the same session identifier, and supports explicit termination.

`EngineInstaller` downloads or accepts a local engine archive, verifies its
SHA-256 digest, rejects unsafe archive paths, extracts it into a versioned
location outside the application bundle, and returns an `EngineDescriptor`.

Engine catalog entries describe versioned installations stored outside
`Still.app`, preserving installed engines across routine frontend builds.

`SteamBootstrapper` reuses one recipe-tagged Steam bottle or provisions it with
Wine Staging. `WindowsInstallerDownloader` permits only HTTPS downloads whose initial
and final hosts are allowlisted, validates the PE header, and records SHA-256.
`SteamLibraryScanner` reads Valve KeyValue manifests without invoking Steam and
maps each discovered title back to `steam.exe -applaunch <appid>`.
`WindowsExecutableScanner` conservatively discovers user-facing executables,
while `JSONApplicationPinStore` persists manually selected launchers only after
verifying that they are existing `.exe` files inside the selected bottle.
Bottle engine selection is mutable metadata, so an installed engine can be
changed without moving or rebuilding the prefix.
