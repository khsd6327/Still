#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 BASE_VERSION_ROOT MOLTENVK_1_4_1_DYLIB ENGINES_ROOT" >&2
    exit 64
fi

base_root=$1
moltenvk_source=$2
engines_root=$3
candidate_id="still-wine-staging-11.14-dxmt-stable-3525d41-mvk141-candidate"
candidate_version="11.14-stable1-mvk141"
candidate_root="$engines_root/$candidate_id/$candidate_version"
runtime_relative="Wine Staging.app/Contents/Resources/wine"
moltenvk_relative="$runtime_relative/lib/libMoltenVK.dylib"

if [ ! -d "$base_root" ] || [ ! -f "$base_root/still-engine.json" ]; then
    echo "error: the base engine is not registered" >&2
    exit 66
fi
if [ ! -f "$moltenvk_source" ] || ! /usr/bin/strings "$moltenvk_source" | /usr/bin/grep -qx '1.4.1'; then
    echo "error: the candidate library does not identify itself as MoltenVK 1.4.1" >&2
    exit 65
fi
if [ -e "$candidate_root" ]; then
    echo "error: the candidate destination already exists" >&2
    exit 73
fi

/bin/mkdir -p "$(/usr/bin/dirname "$candidate_root")"
/usr/bin/ditto --rsrc --extattr "$base_root" "$candidate_root"
/usr/bin/install -m 755 "$moltenvk_source" "$candidate_root/$moltenvk_relative"
/bin/rm "$candidate_root/still-engine.json"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$script_dir/register-local-engine-build.sh" \
    "$candidate_root" \
    "$candidate_id" \
    wineStaging \
    "Still Wine Staging 11.14 + DXMT + MoltenVK 1.4.1 Candidate" \
    "$candidate_version" \
    "Wine Staging.app" \
    "Contents/Resources/wine/bin/wine" \
    43

echo "$candidate_root"
