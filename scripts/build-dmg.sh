#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="dist/Macs Fan Control.app"
codesign --verify --deep --strict "$app"
tools_dir=.build/dmg-tools
if [[ ! -x "$tools_dir/bin/python" ]]; then python3 -m venv "$tools_dir"; fi
"$tools_dir/bin/python" -m pip install --disable-pip-version-check -r Packaging/dmg-requirements.txt
staging=$(mktemp -d "$PWD/dist/.dmg-build.XXXXXX")
trap 'rm -rf "$staging"' EXIT
swift scripts/dmg-background.swift "$staging/background.tiff"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
architecture=$(lipo -archs "$app/Contents/MacOS/FanControl")
# Unique volume names prevent Finder background aliases resolving to older mounts.
"$tools_dir/bin/python" -m dmgbuild -s Packaging/dmg-settings.py \
    -D background="$staging/background.tiff" \
    "Macs Fan Control $version $architecture" "$staging/Macs-Fan-Control.dmg"
hdiutil verify "$staging/Macs-Fan-Control.dmg"
mv "$staging/Macs-Fan-Control.dmg" "dist/Macs-Fan-Control-$architecture.dmg"
