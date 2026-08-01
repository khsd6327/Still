#!/bin/sh
set -eu

if [ "$#" -ne 5 ]; then
    echo "usage: $0 RUNTIME_ROOT WINE_VERSION DXMT_REVISION WINEMAC_SO WINEMETAL_SO" >&2
    exit 64
fi

runtime_root=$1
wine_version=$2
dxmt_revision=$3
winemac_source=$4
winemetal_source=$5
unix_lib="$runtime_root/lib/wine/x86_64-unix"
manifest_dir="$runtime_root/share/still"
winemac_target="$unix_lib/winemac.so"
winemetal_target="$unix_lib/winemetal.so"
manifest_target="$manifest_dir/dxmt-bridge.json"

for artifact in "$winemac_source" "$winemetal_source"; do
    if [ ! -f "$artifact" ]; then
        echo "error: bridge artifact not found: $artifact" >&2
        exit 66
    fi
done

mkdir -p "$unix_lib" "$manifest_dir"
install -m 755 "$winemac_source" "$winemac_target"
install -m 755 "$winemetal_source" "$winemetal_target"

winemac_sha=$(/usr/bin/shasum -a 256 "$winemac_target" | /usr/bin/awk '{print $1}')
winemetal_sha=$(/usr/bin/shasum -a 256 "$winemetal_target" | /usr/bin/awk '{print $1}')

/usr/bin/printf '%s\n' \
    '{' \
    '  "contractID": "app.stillproject.dxmt-bridge",' \
    '  "abiVersion": 1,' \
    "  \"wineVersion\": \"$wine_version\"," \
    "  \"dxmtRevision\": \"$dxmt_revision\"," \
    '  "artifacts": [' \
    "    {\"relativePath\": \"lib/wine/x86_64-unix/winemac.so\", \"sha256\": \"$winemac_sha\"}," \
    "    {\"relativePath\": \"lib/wine/x86_64-unix/winemetal.so\", \"sha256\": \"$winemetal_sha\"}" \
    '  ]' \
    '}' > "$manifest_target"

/usr/bin/ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$manifest_target"
echo "$manifest_target"
