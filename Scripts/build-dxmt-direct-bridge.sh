#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <dxmt-source> <build-directory> <wine-build-path>" >&2
    exit 64
fi

source_dir=$1
build_dir=$2
wine_build_path=$3
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
patch_file="$script_dir/../Patches/dxmt-3525d41-direct-winemac-bridge.patch"
expected_revision=3525d41c71604ed07d796de5b58560e3cf6db944

if [ ! -f "$source_dir/src/winemetal/unix/winemetal_unix.c" ]; then
    echo "error: the source directory is not a DXMT source tree" >&2
    exit 66
fi

if [ ! -f "$wine_build_path/Makefile" ]; then
    echo "error: the Wine build path is not configured" >&2
    exit 66
fi

if [ -d "$source_dir/.git" ]; then
    source_revision=$(git -C "$source_dir" rev-parse HEAD)
    if [ "$source_revision" != "$expected_revision" ]; then
        echo "error: expected DXMT revision $expected_revision, found $source_revision" >&2
        exit 65
    fi
fi

if git -C "$source_dir" apply --check "$patch_file" 2>/dev/null; then
    git -C "$source_dir" apply "$patch_file"
elif ! git -C "$source_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
    echo "error: the direct bridge patch neither applies cleanly nor is already applied" >&2
    exit 65
fi

make -C "$wine_build_path" -j "${STILL_BUILD_JOBS:-8}" \
    libs/winecrt0/x86_64-windows/libwinecrt0.a \
    dlls/ntdll/x86_64-windows/libntdll.a \
    dlls/dbghelp/x86_64-windows/libdbghelp.a \
    tools/winebuild/winebuild

meson_bin=${STILL_MESON_BIN:-$(command -v meson || true)}
ninja_bin=${STILL_NINJA_BIN:-$(command -v ninja || true)}
if [ ! -x "$meson_bin" ] || [ ! -x "$ninja_bin" ]; then
    echo "error: Meson and Ninja are required" >&2
    exit 69
fi

NINJA="$ninja_bin" "$meson_bin" setup "$build_dir" "$source_dir" \
    --cross-file "$source_dir/build-win64.txt" --buildtype=release \
    -Dwine_build_path="$wine_build_path" \
    -Dnative_llvm_path="${STILL_LLVM_PATH:-/opt/homebrew/opt/llvm@15}"
NINJA="$ninja_bin" "$meson_bin" compile -C "$build_dir" \
    "src/winemetal/unix/winemetal.so"

echo "$build_dir/src/winemetal/unix/winemetal.so"
