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
Scripts/build-dxmt-direct-bridge.sh <dxmt-source> <build-directory>
```

Stage the compatible artifacts and generate their integrity manifest with:

```sh
Scripts/package-dxmt-direct-bridge.sh <engine-root> <winemac.so> <winemetal.so>
```

Still validates the ABI version, producer ownership, artifact hashes, and
runtime paths before reporting the bridge as available. Default application
launches use the direct bridge. The compatibility shim remains a Debug-only,
explicitly enabled diagnostic tool.

## Storage location

```text
~/Library/Application Support/app.stillproject.still/Engines/
```

Each engine is stored under its manifest identifier and version.
