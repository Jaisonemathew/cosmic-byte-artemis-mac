#!/bin/zsh
# Builds the CLI (build/artemis-rgb) and the menu bar app (build/Artemis RGB.app).
# Needs only the Xcode Command Line Tools (swiftc).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O cli/main.swift -o build/artemis-rgb
APP="build/Artemis RGB.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -parse-as-library -O app/ArtemisRGB.swift -o "$APP/Contents/MacOS/ArtemisRGB"
cp app/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources" && cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s - "$APP"
echo "Built build/artemis-rgb and $APP"
