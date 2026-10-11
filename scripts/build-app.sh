#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p "$PWD/dist"
destination="$PWD/dist/Macs Fan Control Swift.app"
staging="$(mktemp -d "$PWD/dist/.fan-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Macs Fan Control Swift.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchDaemons"
cp "$binary_dir/FanControl" "$binary_dir/FanHelper" "$app/Contents/MacOS/"
cp Packaging/Info.plist "$app/Contents/Info.plist"
cp Packaging/local.macsfancontrol.swift.helper.plist "$app/Contents/Library/LaunchDaemons/"
cp -R "$binary_dir/MacsFanControlSwift_FanCore.bundle" "$app/Contents/Resources/"
swift scripts/make-icon.swift .build/FanControl.iconset
iconutil -c icns .build/FanControl.iconset -o "$app/Contents/Resources/FanControl.icns"
identity="${SIGNING_IDENTITY:--}"
codesign --force --options runtime --sign "$identity" --identifier local.macsfancontrol.swift.helper "$app/Contents/MacOS/FanHelper"
codesign --force --options runtime --sign "$identity" --identifier local.macsfancontrol.swift "$app"
codesign --verify --deep --strict "$app"
# Replace the bundle without modifying the executable inode of a running build.
if [[ -e "$destination" ]]; then mv "$destination" "$staging/previous.app"; fi
if ! mv "$app" "$destination"; then
    if [[ -e "$staging/previous.app" ]]; then mv "$staging/previous.app" "$destination"; fi
    exit 1
fi
printf '\nBuilt: %s\n' "$destination"
