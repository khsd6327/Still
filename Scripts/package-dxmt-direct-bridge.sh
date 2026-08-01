#!/bin/sh
set -eu

if [ "$#" -ne 7 ]; then
    echo "usage: $0 RUNTIME_ROOT WINE_VERSION DXMT_REVISION WINEMAC_SO WINEMETAL_SO KERNELBASE_DLL DXMT_WINDOWS_DIR" >&2
    exit 64
fi

runtime_root=$1
wine_version=$2
dxmt_revision=$3
winemac_source=$4
winemetal_source=$5
kernelbase_source=$6
dxmt_windows_dir=$7
unix_lib="$runtime_root/lib/wine/x86_64-unix"
windows_lib="$runtime_root/lib/wine/x86_64-windows"
manifest_dir="$runtime_root/share/still"
winemac_target="$unix_lib/winemac.so"
winemetal_target="$unix_lib/winemetal.so"
kernelbase_target="$windows_lib/kernelbase.dll"
winemetal_dll_target="$windows_lib/winemetal.dll"
d3d11_target="$windows_lib/d3d11.dll"
dxgi_target="$windows_lib/dxgi.dll"
d3d10core_target="$windows_lib/d3d10core.dll"
manifest_target="$manifest_dir/dxmt-bridge.json"

for artifact in \
    "$winemac_source" \
    "$winemetal_source" \
    "$kernelbase_source" \
    "$dxmt_windows_dir/winemetal.dll" \
    "$dxmt_windows_dir/d3d11.dll" \
    "$dxmt_windows_dir/dxgi.dll" \
    "$dxmt_windows_dir/d3d10core.dll"
do
    if [ ! -f "$artifact" ]; then
        echo "error: bridge artifact not found: $artifact" >&2
        exit 66
    fi
done

mkdir -p "$unix_lib" "$windows_lib" "$manifest_dir"
install -m 755 "$winemac_source" "$winemac_target"
install -m 755 "$winemetal_source" "$winemetal_target"
install -m 644 "$kernelbase_source" "$kernelbase_target"
install -m 644 "$dxmt_windows_dir/winemetal.dll" "$winemetal_dll_target"
install -m 644 "$dxmt_windows_dir/d3d11.dll" "$d3d11_target"
install -m 644 "$dxmt_windows_dir/dxgi.dll" "$dxgi_target"
install -m 644 "$dxmt_windows_dir/d3d10core.dll" "$d3d10core_target"

winemac_sha=$(/usr/bin/shasum -a 256 "$winemac_target" | /usr/bin/awk '{print $1}')
winemetal_sha=$(/usr/bin/shasum -a 256 "$winemetal_target" | /usr/bin/awk '{print $1}')
kernelbase_sha=$(/usr/bin/shasum -a 256 "$kernelbase_target" | /usr/bin/awk '{print $1}')
winemetal_dll_sha=$(/usr/bin/shasum -a 256 "$winemetal_dll_target" | /usr/bin/awk '{print $1}')
d3d11_sha=$(/usr/bin/shasum -a 256 "$d3d11_target" | /usr/bin/awk '{print $1}')
dxgi_sha=$(/usr/bin/shasum -a 256 "$dxgi_target" | /usr/bin/awk '{print $1}')
d3d10core_sha=$(/usr/bin/shasum -a 256 "$d3d10core_target" | /usr/bin/awk '{print $1}')

/usr/bin/printf '%s\n' \
    '{' \
    '  "contractID": "app.stillproject.dxmt-bridge",' \
    '  "abiVersion": 1,' \
    "  \"wineVersion\": \"$wine_version\"," \
    "  \"dxmtRevision\": \"$dxmt_revision\"," \
    '  "artifacts": [' \
    "    {\"relativePath\": \"lib/wine/x86_64-unix/winemac.so\", \"sha256\": \"$winemac_sha\"}," \
    "    {\"relativePath\": \"lib/wine/x86_64-unix/winemetal.so\", \"sha256\": \"$winemetal_sha\"}," \
    "    {\"relativePath\": \"lib/wine/x86_64-windows/kernelbase.dll\", \"sha256\": \"$kernelbase_sha\"}," \
    "    {\"relativePath\": \"lib/wine/x86_64-windows/winemetal.dll\", \"sha256\": \"$winemetal_dll_sha\"}," \
    "    {\"relativePath\": \"lib/wine/x86_64-windows/d3d11.dll\", \"sha256\": \"$d3d11_sha\"}," \
    "    {\"relativePath\": \"lib/wine/x86_64-windows/dxgi.dll\", \"sha256\": \"$dxgi_sha\"}," \
    "    {\"relativePath\": \"lib/wine/x86_64-windows/d3d10core.dll\", \"sha256\": \"$d3d10core_sha\"}" \
    '  ]' \
    '}' > "$manifest_target"

/usr/bin/ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$manifest_target"
echo "$manifest_target"
