#!/bin/bash
# Assembles build/HwpStudio.app from the SwiftPM binary and signs it.
# SIGN_IDENTITY="Developer ID Application: …" for distribution; ad-hoc otherwise.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$1"
app="$repo_root/build/HwpStudio.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/HwpStudio"
cp "$repo_root/Config/Info.plist" "$app/Contents/Info.plist"
cp "$repo_root/App/Resources/ThirdPartyNotices.txt" "$app/Contents/Resources/"
codesign --force --options runtime \
  --entitlements "$repo_root/Config/HwpStudio.entitlements" \
  --sign "${SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
echo "$app"
