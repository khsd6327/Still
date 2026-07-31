#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
derived_data="$project_dir/.derived-data"
built_app="$derived_data/Build/Products/Debug/Still.app"
installed_app="/Applications/Still.app"

xcodebuild \
    -project "$project_dir/Still.xcodeproj" \
    -scheme Still \
    -configuration Debug \
    -derivedDataPath "$derived_data" \
    build

if [ ! -x "$built_app/Contents/MacOS/Still" ]; then
    echo "error: Xcode did not produce the expected Still.app" >&2
    exit 70
fi

built_hash=$(shasum -a 256 "$built_app/Contents/MacOS/Still" | cut -d ' ' -f 1)
installed_hash=$(shasum -a 256 "$installed_app/Contents/MacOS/Still" | cut -d ' ' -f 1)

if [ "$built_hash" != "$installed_hash" ]; then
    echo "error: /Applications/Still.app does not match the Debug product" >&2
    exit 74
fi

echo "$built_app"
echo "$installed_app"
echo "sha256=$built_hash"
