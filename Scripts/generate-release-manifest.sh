#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 STILL_APP OUTPUT_JSON" >&2
    exit 64
fi

app=$1
output=$2
if [ ! -d "$app" ] || [ ! -x "$app/Contents/MacOS/Still" ]; then
    echo "error: invalid Still.app bundle" >&2
    exit 66
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
commit=$(git rev-parse HEAD)

/usr/bin/ruby -rjson -rdigest -e '
  app, output, version, build, commit = ARGV
  root = File.realpath(app)
  artifacts = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
    .select { |path| File.file?(path) && !File.symlink?(path) }
    .sort
    .map do |path|
      {
        "relativePath" => path.delete_prefix(root + File::SEPARATOR),
        "byteCount" => File.size(path),
        "sha256" => Digest::SHA256.file(path).hexdigest
      }
    end
  document = {
    "contractID" => "app.stillproject.release-manifest",
    "schemaVersion" => 1,
    "version" => version,
    "build" => build,
    "sourceCommit" => commit,
    "artifacts" => artifacts
  }
  File.write(output, JSON.pretty_generate(document) + "\n")
' "$app" "$output" "$version" "$build" "$commit"

/usr/bin/shasum -a 256 "$output"
