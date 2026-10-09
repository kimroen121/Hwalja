#!/bin/bash
# Assembles build/hwalja.app from the SwiftPM binary and signs it.
# SIGN_IDENTITY="Developer ID Application: …" for distribution; ad-hoc otherwise.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$1"
app="$repo_root/build/hwalja.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# SwiftPM records the deployment target as the SDK version, which keeps the old window look
# (no Liquid Glass) on new macOS; record the SDK actually built with.
minimum="$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$repo_root/Config/Info.plist")"
xcrun vtool -set-build-version macos "$minimum" "$(xcrun --show-sdk-version)" -replace \
  -output "$app/Contents/MacOS/Hwalja" "$binary"
cp "$repo_root/Config/Info.plist" "$app/Contents/Info.plist"
python3 "$repo_root/scripts/third-party-notices.py" > "$app/Contents/Resources/ThirdPartyNotices.txt"
# App icon (Icon Composer), compiled to Assets.car and an .icns for macOS before 26.
xcrun actool "$repo_root/docs/brand/hwalja.icon" --compile "$app/Contents/Resources" \
  --platform macosx --minimum-deployment-target "$minimum" --app-icon hwalja \
  --output-partial-info-plist /dev/null >/dev/null
# SwiftMath's fonts, where its resource lookup finds them.
cp -R "$(dirname "$binary")/SwiftMath_SwiftMath.bundle" "$app/Contents/Resources/"
# Quick Look preview extension, built next to the app binary.
appex="$app/Contents/PlugIns/HwaljaPreview.appex"
mkdir -p "$appex/Contents/MacOS" "$appex/Contents/Resources"
xcrun vtool -set-build-version macos "$minimum" "$(xcrun --show-sdk-version)" -replace \
  -output "$appex/Contents/MacOS/HwaljaPreview" "$(dirname "$binary")/HwaljaPreview"
cp "$repo_root/Config/Preview-Info.plist" "$appex/Contents/Info.plist"
cp -R "$(dirname "$binary")/SwiftMath_SwiftMath.bundle" "$appex/Contents/Resources/"
codesign --force --options runtime \
  --entitlements "$repo_root/Config/HwaljaPreview.entitlements" \
  --sign "${SIGN_IDENTITY:--}" "$appex"
codesign --force --options runtime \
  --entitlements "$repo_root/Config/Hwalja.entitlements" \
  --sign "${SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
echo "$app"
