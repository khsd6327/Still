#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 STILL_APP OUTPUT_ZIP" >&2
    exit 64
fi

: "${STILL_DEVELOPER_ID:?Set STILL_DEVELOPER_ID to a Developer ID Application identity}"
: "${STILL_NOTARY_PROFILE:?Set STILL_NOTARY_PROFILE to a notarytool keychain profile}"

app=$1
output=$2
/usr/bin/codesign --force --deep --options runtime --timestamp \
    --sign "$STILL_DEVELOPER_ID" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
/usr/bin/ditto -c -k --keepParent "$app" "$output"
/usr/bin/xcrun notarytool submit "$output" \
    --keychain-profile "$STILL_NOTARY_PROFILE" --wait
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"
