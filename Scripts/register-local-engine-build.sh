#!/bin/sh
set -eu

if [ "$#" -ne 8 ]; then
    echo "usage: $0 VERSION_ROOT ENGINE_ID FAMILY DISPLAY_NAME VERSION ARCHIVE_ROOT WINE_BINARY_RELATIVE_PATH CAPABILITIES_RAW" >&2
    exit 64
fi

version_root=$1
engine_id=$2
family=$3
display_name=$4
version=$5
archive_root=$6
wine_binary_relative_path=$7
capabilities_raw=$8
manifest_target="$version_root/still-engine.json"
wine_binary="$version_root/$archive_root/$wine_binary_relative_path"

case "$engine_id:$version:$archive_root:$wine_binary_relative_path" in
    *..*|*//*|/*)
        echo "error: unsafe local engine path" >&2
        exit 65
        ;;
esac

if [ ! -x "$wine_binary" ]; then
    echo "error: Wine binary is not executable: $wine_binary" >&2
    exit 66
fi

case "$family" in
    wineStable|wineDevel|wineStaging|gamePortingToolkit) ;;
    *)
        echo "error: unsupported engine family: $family" >&2
        exit 65
        ;;
esac

case "$capabilities_raw" in
    ''|*[!0-9]*)
        echo "error: capabilities must be an unsigned integer" >&2
        exit 65
        ;;
esac

/usr/bin/ruby -rjson -e '
  target, id, family, display_name, version, archive_root, wine_path, capabilities = ARGV
  document = {
    "contractID" => "app.stillproject.engine-build",
    "schemaVersion" => 1,
    "id" => id,
    "family" => family,
    "displayName" => display_name,
    "version" => version,
    "archiveRoot" => archive_root,
    "wineBinaryRelativePath" => wine_path,
    "capabilities" => Integer(capabilities, 10)
  }
  File.write(target, JSON.pretty_generate(document) + "\n")
' "$manifest_target" "$engine_id" "$family" "$display_name" "$version" \
  "$archive_root" "$wine_binary_relative_path" "$capabilities_raw"
echo "$manifest_target"
