# Still architecture

## Design goals

1. Treat Wine builds as replaceable engines.
2. Keep graphics backends independent from Wine engine selection.
3. Store enough metadata to reproduce an Environment configuration.
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

### Application

An application is the primary Library object. It owns stable launch entries,
category, provider metadata, and a reference to its Environment.

### Environment

An Environment describes a Wine prefix and the reproducible configuration used
to run applications inside it. The prefix itself remains ordinary Wine data.
Legacy bottle types remain only as migration and low-level runtime adapters.

### Engine

An engine is a versioned Wine installation. Engine identity is stored separately
from its local installation path so an engine can be reinstalled or relocated.

### Graphics backend

The graphics backend is selected per application or Environment. D3DMetal is represented as an
optional externally supplied backend and is not bundled by Still.

### Profile

A Profile describes validated engine, Windows version, graphics backend,
dependency, and launch defaults for an application. Profiles remain declarative
and versioned. They never contain executable scripts.

## Implemented runtime path

`LocalWineEngine` converts an Environment launch request into a `ProcessPlan` through
`WineCommandBuilder`. `ProcessSupervisor` starts the executable without a shell,
captures standard output and standard error in a per-session log, tracks the
process by the same session identifier, and supports explicit termination.

`EngineInstaller` downloads or accepts a local engine archive, verifies its
SHA-256 digest, rejects unsafe archive paths, extracts it into a versioned
location outside the application bundle, and returns an `EngineDescriptor`.

Engine catalog entries describe versioned installations stored outside
`Still.app`, preserving installed engines across routine frontend builds.

The Install workflow accepts a local EXE or MSI and applies a matching Profile
when one is validated. `SteamLibraryScanner` reads provider manifests and maps
each discovered title to its provider launch entry.

The DXMT integration uses a versioned direct ABI between patched open Wine and
DXMT builds. An optional diagnostic launch plan can enable the legacy injected
shim in Debug builds.

`WindowsExecutableScanner` conservatively discovers user-facing executables,
while `JSONApplicationPinStore` persists manually selected launchers only after
verifying that they are existing `.exe` files inside the selected Environment.
Engine changes are guarded operations that require stopped sessions, explicit
approval, and a Restore Point.
