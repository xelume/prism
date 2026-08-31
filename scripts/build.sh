#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
minimumOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' info.plist)
export MACOSX_DEPLOYMENT_TARGET="$minimumOS"
mkdir -p build/moduleCache
app="build/Xelume Switch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/moduleCache" \
  scripts/generateIcons.swift -o build/generateIcons
build/generateIcons assets/logo.svg build/icons
iconutil -c icns build/icons/appIcon.iconset -o "$app/Contents/Resources/appIcon.icns"
cp build/icons/menuIcon.png build/icons/menuIcon@2x.png "$app/Contents/Resources/"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx${minimumOS}" -module-cache-path "$PWD/build/moduleCache" \
  sources/authStore.swift sources/accountUsage.swift sources/usageMonitor.swift sources/clientShutdown.swift sources/processControl.swift \
  sources/macRuntime.swift sources/menuApp.swift sources/main.swift \
  -o "$app/Contents/MacOS/XelumeSwitch"
cp info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier local.chatgptAccountSwitcher "$app"
codesign --verify --strict "$app"
bash scripts/createDmg.sh "$app" build/xelumeSwitch.dmg
echo "Built: $PWD/$app"
echo "Packaged: $PWD/build/xelumeSwitch.dmg"
