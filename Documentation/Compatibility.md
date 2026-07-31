# Compatibility

Still runs Windows applications through external Wine-compatible engines. An
application's result depends on its engine, graphics backend, Windows version,
runtime dependencies, and application-specific requirements.

## Configuration model

Each bottle stores its engine and compatibility configuration independently.
Supported settings include:

1. Wine engine and version.
2. Graphics backend.
3. Windows version.
4. Synchronization mode.
5. Launch arguments and environment overrides.
6. Required DLL overrides and redistributable packages.

Settings remain inspectable and reversible. Engine replacement, application
downgrade, and obsolete launcher installation require explicit operations.

## Engine policy

An installable engine entry must provide an upstream source, exact version,
archive hash, supported architecture, requirements, and distribution policy.
Downloads are verified before extraction. Components that require separate
license acceptance are not installed without confirmation.

A graphics backend is considered active only when its required files and DLL
overrides are present in the selected bottle.

## Application profiles

Application profiles may provide tested defaults for an executable. A profile
can specify an engine family, graphics backend, Windows version, launch
arguments, environment variables, DLL overrides, and required runtime
packages. Users can inspect and override these settings.

## Known boundaries

- Kernel-level Windows anti-cheat systems are generally unsupported.
- Compatibility results are specific to the tested application and version.
- Reaching a menu or rendering a frame does not establish stable playability.

## Steam libraries

Still reads installed game metadata from Steam library manifests. Steam helper
executables are excluded from the application library, and each Steam install
remains isolated inside its bottle.
