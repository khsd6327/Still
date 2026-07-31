# Engines

Still keeps Wine-compatible engines outside the application bundle. Rebuilding
or replacing `Still.app` does not remove installed engines or bottles.

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

## Wine and DXMT bridge

Still includes source patches for its Wine 11.14 Metal presentation path. Build
the driver and bridge from the exact `wine-11.14` tag with:

```sh
STILL_WINE_RAW_ANGLE=1 STILL_WINE_DXMT_BRIDGE=1 \
  Scripts/build-wine-11.14-macdrv.sh <wine-source> <build-directory>
```

The command produces `winemac.so`, `kernelbase.dll`, and
`libstill-dxmt-macdrv-bridge.dylib`. Place the bridge beside the Unix Wine
libraries at:

```text
<engine>/Contents/Resources/wine/lib/wine/x86_64-unix/
```

DXMT's `winemetal.so` and Windows DLLs must be supplied by the selected engine.
Still does not currently assemble this engine configuration automatically.

When a bottle selects DXMT, Still applies native overrides for `dxgi`, `d3d9`,
`d3d10core`, and `d3d11`. The bridge is loaded only when its dylib exists in the
selected engine.

## Storage location

```text
~/Library/Application Support/app.stillproject.still/Engines/
```

Each engine is stored under its manifest identifier and version.
