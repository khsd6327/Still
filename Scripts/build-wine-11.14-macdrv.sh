#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <wine-11.14-source> <build-directory>" >&2
    exit 64
fi

source_dir=$1
build_dir=$2
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
patch_file="$script_dir/../Patches/wine-11.14-cross-process-metal.patch"
stable_export_patch="$script_dir/../Patches/wine-11.14-stable-metal-export.patch"
raw_angle_patch="$script_dir/../Patches/wine-11.14-steam-webhelper-angle.patch"
dxmt_bridge_patch="$script_dir/../Patches/wine-11.14-dxmt-macdrv-bridge.patch"
dxmt_bridge_source="$script_dir/../Sources/StillBridge/dxmt-macdrv-bridge-shim.c"

if [ ! -f "$source_dir/configure" ] || [ ! -f "$source_dir/dlls/winemac.drv/window.c" ]; then
    echo "error: the source directory is not a Wine source tree" >&2
    exit 66
fi

if [ -d "$source_dir/.git" ]; then
    source_tag=$(git -C "$source_dir" describe --tags --exact-match 2>/dev/null || true)
    if [ "$source_tag" != "wine-11.14" ]; then
        echo "error: expected exact Wine tag wine-11.14, found ${source_tag:-untagged}" >&2
        exit 65
    fi
fi

if git -C "$source_dir" apply --check "$patch_file" 2>/dev/null; then
    git -C "$source_dir" apply "$patch_file"
elif ! git -C "$source_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
    echo "error: the Still Wine patch neither applies cleanly nor is already applied" >&2
    exit 65
fi

if [ "${STILL_WINE_STABLE_EXPORT:-0}" = "1" ]; then
    if git -C "$source_dir" apply --check "$stable_export_patch" 2>/dev/null; then
        git -C "$source_dir" apply "$stable_export_patch"
    elif ! git -C "$source_dir" apply --reverse --check "$stable_export_patch" 2>/dev/null; then
        echo "error: the stable Metal export patch neither applies cleanly nor is already applied" >&2
        exit 65
    fi
fi

if [ "${STILL_WINE_RAW_ANGLE:-0}" = "1" ]; then
    if git -C "$source_dir" apply --check "$raw_angle_patch" 2>/dev/null; then
        git -C "$source_dir" apply "$raw_angle_patch"
    elif ! git -C "$source_dir" apply --reverse --check "$raw_angle_patch" 2>/dev/null; then
        echo "error: the Steam WebHelper ANGLE patch neither applies cleanly nor is already applied" >&2
        exit 65
    fi
fi

if git -C "$source_dir" apply --check "$dxmt_bridge_patch" 2>/dev/null; then
    git -C "$source_dir" apply "$dxmt_bridge_patch"
elif ! git -C "$source_dir" apply --reverse --check "$dxmt_bridge_patch" 2>/dev/null; then
    echo "error: the direct DXMT bridge patch neither applies cleanly nor is already applied" >&2
    exit 65
fi

mkdir -p "$build_dir"

if [ ! -f "$build_dir/Makefile" ]; then
    host_triplet="x86_64-apple-darwin$(uname -r)"
    bison_bin=${STILL_BISON_BIN:-/opt/homebrew/opt/bison/bin/bison}
    if [ ! -x "$bison_bin" ]; then
        bison_bin=$(command -v bison)
    fi
    (
        cd "$build_dir"
        CC="clang -arch x86_64" \
        CXX="clang++ -arch x86_64" \
        BISON="$bison_bin" \
        "$source_dir/configure" \
            --build="$host_triplet" \
            --host="$host_triplet" \
            --enable-win64 \
            --without-x \
            --without-freetype \
            --without-gstreamer
    )
fi

make -C "$build_dir" -j "${STILL_BUILD_JOBS:-8}" dlls/winemac.drv/winemac.so

echo "$build_dir/dlls/winemac.drv/winemac.so"

if [ "${STILL_WINE_DXMT_DIAGNOSTIC_SHIM:-0}" = "1" ]; then
    bridge_output="$build_dir/libstill-dxmt-macdrv-bridge.dylib"
    clang -dynamiclib -arch x86_64 -Wall -Wextra -Werror \
        -o "$bridge_output" "$dxmt_bridge_source"
    echo "$bridge_output"
fi

if [ "${STILL_WINE_RAW_ANGLE:-0}" = "1" ]; then
    make -C "$build_dir" -j "${STILL_BUILD_JOBS:-8}" dlls/kernelbase/x86_64-windows/kernelbase.dll
    echo "$build_dir/dlls/kernelbase/x86_64-windows/kernelbase.dll"
fi
