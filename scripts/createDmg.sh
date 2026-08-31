#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 2 || "$2" != *.dmg ]]; then
  echo 'Usage: createDmg.sh <application.app> <output.dmg>' >&2
  exit 1
fi
app=$1
output=$2
appName=$(basename "$app")
test -d "$app"
codesign --verify --deep --strict "$app"
mkdir -p build
work=$(mktemp -d "$PWD/build/dmg.XXXXXX")
mounted=false
cleanup() {
  # Never remove the working directory while its image might still be mounted.
  if [[ "$mounted" == true ]]; then
    if ! hdiutil detach "$work/mount" -quiet; then
      echo "Could not detach verification image; preserved $work" >&2
      return 1
    fi
  fi
  rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$work/content" "$work/mount"
ditto "$app" "$work/content/$appName"
ln -s /Applications "$work/content/Applications"
hdiutil create -srcfolder "$work/content" -volname 'Prism' \
  -fs HFS+ -format UDZO "$work/image.dmg" -quiet
hdiutil verify "$work/image.dmg" -quiet
# No Finder automation or GUI session is needed on a GitHub-hosted runner.
mounted=true
hdiutil attach "$work/image.dmg" -readonly -nobrowse -noautoopen \
  -mountpoint "$work/mount" -quiet
test "$(readlink "$work/mount/Applications")" = /Applications
cmp "$app/Contents/Info.plist" "$work/mount/$appName/Contents/Info.plist"
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
cmp "$app/Contents/MacOS/$executable" "$work/mount/$appName/Contents/MacOS/$executable"
codesign --verify --deep --strict "$work/mount/$appName"
hdiutil detach "$work/mount" -quiet
mounted=false
mkdir -p "$(dirname "$output")"
mv -f "$work/image.dmg" "$output"
printf 'Created and verified DMG: %s\n' "$output"
