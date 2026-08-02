# Engines

Still stores Wine-compatible engines and Environments independently from the
application bundle, preserving them when `Still.app` is rebuilt or replaced.

## Engine catalog

| Engine | Upstream | Version | Installation |
| --- | --- | --- | --- |
| Wine Stable | Gcenx/macOS_Wine_builds | 11.0_1 | Downloaded on demand |
| Wine Devel | Gcenx/macOS_Wine_builds | 11.14 | Downloaded on demand |
| Wine Staging | Gcenx/macOS_Wine_builds | 11.14 | Downloaded on demand |
| Game Porting Toolkit | Gcenx/game-porting-toolkit | 3.0-3 | Requires external license acceptance |

Catalog entries pin the upstream URL, expected byte size, and SHA-256 digest.
Archives with a mismatched digest or unsafe path are rejected.

The Gcenx Wine packages require the matching system-wide GStreamer framework.
Game Porting Toolkit installation requires acceptance of Apple's license.

## Direct Wine and DXMT bridge

Still includes source patches for a versioned, direct Wine-to-DXMT Metal
presentation contract. Build the Wine driver from the exact `wine-11.14` tag
with:

```sh
Scripts/build-wine-11.14-macdrv.sh <wine-source> <build-directory>
```

Build DXMT from the pinned source revision with:

```sh
Scripts/build-dxmt-direct-bridge.sh <dxmt-source> <build-directory> <wine-build-directory>
```

Stage the compatible artifacts and generate their integrity manifest with:

```sh
Scripts/package-dxmt-direct-bridge.sh \
  <engine-root> <wine-version> <dxmt-revision> \
  <winemac.so> <winemetal.so> <kernelbase.dll> <dxmt-windows-directory>
```

Register a source-built engine after staging its Wine bundle:

```sh
Scripts/register-local-engine-build.sh \
  <version-root> <engine-id> <family> <display-name> <version> \
  <archive-root> <wine-binary-relative-path> <capabilities>
```

Still validates the ABI version, producer ownership, artifact hashes, and
runtime paths before reporting the bridge as available. Default application
launches use the direct bridge. Steam launches on this source-built runtime use
the Raw ANGLE Wine path selected by `STILL_STEAM_CEF_RAW_ANGLE=1`. The compatibility
shim remains a Debug-only, explicitly enabled diagnostic tool.

## Storage location

```text
~/Library/Application Support/app.stillproject.still/Engines/
```

Each engine is stored under its manifest identifier and version. Source-built
engines are discovered from a version-root `still-engine.json` manifest. The
manifest records the Wine executable and direct-bridge artifacts with their
byte sizes, executable attributes, and SHA-256 digests. Still verifies the
complete list before making the engine available for Environment selection.

Verified compatibility profiles additionally require the exact engine ID and
the SHA-256 digest of `still-engine.json`. The complete source, patch, bridge,
MoltenVK, and artifact identity is recorded in
`Documentation/Verified-Engine-Builds.json`.
