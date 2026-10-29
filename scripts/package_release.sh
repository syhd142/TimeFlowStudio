#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-0.1.0-beta.1}"
architecture="$(uname -m)"
release_dir="$project_dir/dist/releases"
app_path="$project_dir/dist/TimeFlow Studio.app"
base_name="TimeFlow-Studio-$version-$architecture"
dmg_path="$release_dir/$base_name.dmg"
checksum_path="$release_dir/$base_name.sha256"
release_tmp="$(mktemp -d /private/tmp/timeflow-release.XXXXXX)"
verify_mount="$(mktemp -d /private/tmp/timeflow-dmg-verify.XXXXXX)"
packaged_app="$release_tmp/TimeFlow Studio.app"
signing_identity="${TIMEFLOW_SIGNING_IDENTITY:--}"
is_mounted=false

cleanup() {
  if [[ "$is_mounted" == true ]]; then
    hdiutil detach "$verify_mount" >/dev/null || true
  fi
  rm -rf "$release_tmp"
  rmdir "$verify_mount" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$release_dir"
"$project_dir/scripts/package_app.sh"

ditto --norsrc --noextattr "$app_path" "$packaged_app"
cp "$project_dir/README.zh-CN.md" "$release_tmp/README.zh-CN.md"
cp "$project_dir/LICENSE" "$release_tmp/LICENSE.txt"
xattr -cr "$packaged_app"
codesign --force --deep --sign "$signing_identity" "$packaged_app"
codesign --verify --deep --strict --verbose=2 "$packaged_app"

if [[ -e "$dmg_path" ]]; then
  rm "$dmg_path"
fi

hdiutil create \
  -volname "TimeFlow Studio $version" \
  -srcfolder "$release_tmp" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$dmg_path"

(cd "$release_dir" && shasum -a 256 "$(basename "$dmg_path")") > "$checksum_path"

hdiutil attach -readonly -nobrowse -mountpoint "$verify_mount" "$dmg_path" >/dev/null
is_mounted=true
codesign --verify --deep --strict --verbose=2 "$verify_mount/TimeFlow Studio.app"
file "$verify_mount/TimeFlow Studio.app/Contents/MacOS/TimeFlow"
hdiutil detach "$verify_mount" >/dev/null
is_mounted=false

echo "$dmg_path"
echo "$checksum_path"
