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

/usr/bin/ruby -rjson -rdigest -rpathname -e '
  target, version_root, id, family, display_name, version, archive_root, wine_path, capabilities = ARGV
  root = Pathname(version_root).realpath
  wine_relative_path = File.join(archive_root, wine_path)
  wine_binary = root.join(wine_relative_path)
  runtime_root = wine_binary.dirname.dirname
  bridge_manifest = runtime_root.join("share/still/dxmt-bridge.json")
  wine_version = nil
  dxmt_revision = nil

  if bridge_manifest.file?
    bridge = JSON.parse(bridge_manifest.read)
    wine_version = bridge.fetch("wineVersion")
    dxmt_revision = bridge.fetch("dxmtRevision")
  elsif (Integer(capabilities, 10) & 32) != 0
    abort("error: a DXMT engine requires a direct bridge manifest")
  end

  relative_paths = Dir.glob(root.join("**", "*").to_s, File::FNM_DOTMATCH)
    .map { |path| Pathname(path) }
    .select do |candidate|
      candidate != root && candidate.basename.to_s != "." &&
        candidate.basename.to_s != ".." && candidate.lstat.file? &&
        !candidate.lstat.symlink? && candidate != Pathname(target)
    end
    .map { |candidate| candidate.relative_path_from(root).to_s }
    .uniq
    .sort

  artifacts = relative_paths.map do |relative_path|
    candidate = root.join(relative_path)
    resolved = candidate.realpath
    unless resolved.to_s.start_with?(root.to_s + File::SEPARATOR) &&
           candidate.lstat.file? && !candidate.lstat.symlink?
      abort("error: unsafe engine artifact: #{relative_path}")
    end
    {
      "relativePath" => relative_path,
      "sha256" => Digest::SHA256.file(candidate).hexdigest,
      "byteCount" => candidate.size,
      "isExecutable" => candidate.executable?
    }
  end

  document = {
    "contractID" => "app.stillproject.engine-build",
    "schemaVersion" => 2,
    "id" => id,
    "family" => family,
    "displayName" => display_name,
    "version" => version,
    "archiveRoot" => archive_root,
    "wineBinaryRelativePath" => wine_path,
    "wineVersion" => wine_version,
    "dxmtRevision" => dxmt_revision,
    "capabilities" => Integer(capabilities, 10),
    "artifacts" => artifacts
  }
  File.write(target, JSON.pretty_generate(document) + "\n")
' "$manifest_target" "$version_root" "$engine_id" "$family" "$display_name" "$version" \
  "$archive_root" "$wine_binary_relative_path" "$capabilities_raw"
echo "$manifest_target"
