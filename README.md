![Still banner](Documentation/Assets/still-readme-banner.png)

# Still

Still is a native macOS application for organizing and running Windows apps
and games with interchangeable Wine-compatible engines.

Applications, bottles, engines, graphics backends, and processes are modeled
separately. This keeps the library independent from any single launcher or
compatibility engine.

## Status

Still `0.1.0-alpha.1` is an early preview intended for evaluation and
development. Application compatibility varies by engine, macOS version, and
graphics backend. Still uses Alpha, Beta, and Stable release channels. Current
builds are ad hoc signed and are not notarized.

## Features

- Create and manage isolated Wine bottles.
- Install and switch versioned Wine-compatible engines.
- Configure graphics and synchronization options per bottle.
- Discover installed Windows applications and pin additional executables.
- Install Steam from Valve and import its installed game library.
- View and stop Wine processes by application or bottle.
- Keep launch logs for troubleshooting.
- Use the native macOS interface or command-line diagnostics.

## Requirements

- Apple silicon Mac. Intel Macs are not supported.
- macOS 26 or later.
- A compatible Wine engine for the selected application.

## Compatibility

Compatibility depends on the application, engine, macOS version, graphics
backend, and runtime configuration. Validated results record the exact boundary
reached by each tested configuration.

See [Compatibility](Documentation/Compatibility.md) and
[Engines](Documentation/Engines.md) for supported configuration boundaries.
Validated application results are recorded in
[Compatibility results](Documentation/Compatibility-Results.md).


## Development

Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) are
required to regenerate the project:

```sh
xcodegen generate
open Still.xcodeproj
```

Run the package tests and diagnostics:

```sh
swift build
swift test
swift run still-cli info
swift run still-cli engines
swift run still-cli scan-apps
```

Build the Debug application and update `/Applications/Still.app`:

```sh
Scripts/build-and-install-debug.sh
```

The script verifies that the built and installed executables have matching
SHA-256 digests.

Bug reports and pull requests are welcome. See
[Contributing](CONTRIBUTING.md) before submitting a change. Security issues
must be reported privately as described in [Security](SECURITY.md).

## Repository structure

```text
Sources/
  StillCore/       Models, persistence, engines, scanning, and processes
  StillDesktop/    Native macOS interface
  StillCLI/        Command-line operations
  StillChecks/     Runtime diagnostics
  StillBridge/     Native compatibility bridge source
Tests/
  StillCoreTests/
Documentation/
Patches/
Scripts/
```

## License

Still's original source code is available under the [MIT License](LICENSE).
Wine-derived patches and third-party components retain their respective
licenses. See [Third-party notices](THIRD_PARTY_NOTICES.md).
