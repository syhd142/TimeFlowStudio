#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
dist_dir="$project_dir/dist"
app_dir="$dist_dir/TimeFlow Studio.app"
contents_dir="$app_dir/Contents"
signing_identity="${TIMEFLOW_SIGNING_IDENTITY:--}"

mkdir -p "$dist_dir"

env \
  CLANG_MODULE_CACHE_PATH=/private/tmp/timeflow-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/timeflow-swiftpm-cache \
  swift build --package-path "$project_dir" --disable-sandbox -c release

if [[ -d "$app_dir" ]]; then
  rm -rf "$app_dir"
fi
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$project_dir/.build/release/TimeFlow" "$contents_dir/MacOS/TimeFlow"
cp "$project_dir/Packaging/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/LICENSE" "$contents_dir/Resources/LICENSE.txt"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$contents_dir/Resources/THIRD_PARTY_NOTICES.md"
chmod 755 "$contents_dir/MacOS/TimeFlow"
xattr -cr "$app_dir"

codesign --force --deep --sign "$signing_identity" "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

echo "$app_dir"
