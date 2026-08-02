# Compatibility

Still runs Windows applications through external Wine-compatible engines. An
application's result depends on its engine, graphics backend, Windows version,
runtime dependencies, and application-specific requirements.

## Configuration model

Each Environment stores its engine and compatibility configuration independently.
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
overrides are present in the selected Environment.

## Application profiles

Application profiles may provide tested defaults for an executable. A profile
can specify an engine family, graphics backend, Windows version, launch
arguments, environment variables, DLL overrides, and required runtime
packages. Users can inspect and override these settings.

## Known boundaries

- Kernel-level Windows anti-cheat systems are generally unsupported.
- Compatibility results are specific to the tested application and version.
- Reaching a menu or rendering a frame does not establish stable playability.

## Visual smoke checks

Steam UI captures can be checked for a nonblank rendered frame with:

```sh
Scripts/verify-visual-smoke.swift ui steam.png
```

Game rendering checks use two captures from the same window after an input or
camera change. Both frames must contain visual structure and differ by the
minimum motion threshold:

```sh
Scripts/verify-visual-smoke.swift motion before.png after.png
```

These checks detect blank-frame regressions and visible frame progression. They
do not change the compatibility boundary recorded for an application.

## Steam libraries

Still reads installed game metadata from Steam library manifests. Steam helper
executables are excluded from the application library, and each Steam install
remains isolated inside its Environment.
