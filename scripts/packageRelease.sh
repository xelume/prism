#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Ask Xcode to resolve xcconfig values; never parse its configuration syntax ourselves.
metadata=$(xcodebuild -project Prism.xcodeproj -scheme Prism -configuration Release \
  -destination 'generic/platform=macOS' -clonedSourcePackagesDirPath build/SourcePackages \
  -disableAutomaticPackageResolution -showBuildSettings -json | python3 -c '
import json, sys
settings = next(item["buildSettings"] for item in json.load(sys.stdin) if item["target"] == "Prism")
keys = ["MARKETING_VERSION", "CURRENT_PROJECT_VERSION", "MACOSX_DEPLOYMENT_TARGET", "PRODUCT_BUNDLE_IDENTIFIER", "EXECUTABLE_NAME"]
print("|".join(settings[key] for key in keys))
')
IFS='|' read -r version buildNumber minimumOS bundleID executable <<< "$metadata"
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
   [[ ! "$buildNumber" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$minimumOS" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo 'Invalid version/build/minimum macOS in Xcode configuration.' >&2
  exit 1
fi
releaseTag=${1:-v$version}
if [[ "$releaseTag" != "v$version" ]]; then
  echo 'Release tag must exactly match v + MARKETING_VERSION.' >&2
  exit 1
fi
if [[ $# -gt 2 ]] || [[ $# -eq 2 && "$2" != --check-only && "$2" != --signed ]]; then
  echo 'Usage: packageRelease.sh [vMAJOR.MINOR.PATCH [--check-only|--signed]]' >&2
  exit 1
fi
if [[ ${2:-} == --check-only ]]; then
  echo "Validated release $releaseTag (build $buildNumber)."
  exit 0
fi

app='build/Prism.xcarchive/Products/Applications/Prism.app'
# Xcode resolves variables and adds platform keys, so compare semantic metadata.
for entry in "CFBundleShortVersionString:$version" "CFBundleVersion:$buildNumber" \
             "LSMinimumSystemVersion:$minimumOS" "CFBundleIdentifier:$bundleID" \
             "CFBundleExecutable:$executable"; do
  key=${entry%%:*}
  expected=${entry#*:}
  actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist")
  if [[ "$actual" != "$expected" ]]; then
    echo "Archive metadata mismatch: $key. Archive the current project again." >&2
    exit 1
  fi
done
codesign --verify --deep --strict "$app"
architecture=$(lipo -archs "$app/Contents/MacOS/$executable")
if [[ "$architecture" != arm64 ]]; then
  echo 'Release packaging currently supports arm64 only.' >&2
  exit 1
fi
archive="prism-$releaseTag-macos-$architecture.dmg"
# Fail closed rather than uploading leftover archives from an older local build.
if [[ -e build/release ]]; then
  echo 'build/release already exists; move it aside before packaging again.' >&2
  exit 1
fi
mkdir -p build/release
bash scripts/createDmg.sh "$app" "build/release/$archive"
(
  cd build/release
  shasum -a 256 "$archive" > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
cat > build/release/releaseNotes.md <<NOTES
Prism $releaseTag (build $buildNumber)

- 安装：打开 DMG，将 Prism.app 拖入 Applications，然后推出磁盘映像，从“应用程序”打开应用。
- 支持 Apple Silicon（arm64），最低 macOS ${minimumOS}。
- 此包仅使用临时（ad-hoc）签名，未经 Developer ID 签名或 Apple 公证，macOS 可能阻止打开。不是正式公证发行版。
- 目前只兼容已检查版本 26.825.51511 的官方 ChatGPT 客户端及默认文件认证。
- 自动化测试不验证真实账号登录、钥匙串授权或真实额度查询，请在推送发布标签前完成必要的人工验收。
- 校验下载文件：将 DMG 与 SHA256SUMS.txt 放在同一目录，运行 shasum -a 256 -c SHA256SUMS.txt。

推送发布标签后，工作流会自动公开完整附件并部署更新订阅。
NOTES
printf 'Packaged: build/release/%s\n' "$archive"

if [[ ${2:-} == --signed ]]; then
  # The public key must already be embedded in the archive. Private signing keys
  # stay in a dedicated Keychain account locally, or enter CI through stdin only.
  sparkleBin='build/SourcePackages/artifacts/sparkle/Sparkle/bin'
  test -x "$sparkleBin/generate_appcast"
  test -f releaseNotes.md
  cp releaseNotes.md "build/release/${archive%.dmg}.md"
  signingArgs=(--account xelume-prism)
  if [[ -n ${SPARKLE_PRIVATE_KEY:-} ]]; then
    signingArgs=(--ed-key-file -)
  elif [[ ${CI:-} == true ]]; then
    echo 'Signed releases require the SPARKLE_PRIVATE_KEY secret.' >&2
    exit 1
  fi
  # printf is a shell builtin: the key never appears in a child process argv.
  printf '%s' "${SPARKLE_PRIVATE_KEY:-}" | "$sparkleBin/generate_appcast" \
    "${signingArgs[@]}" --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/xelume/prism/releases/download/$releaseTag/" \
    --link 'https://github.com/xelume/prism' build/release
  xcrun swift scripts/updateFeed.swift validate build/release/appcast.xml \
    "build/release/$archive" "$app/Contents/Info.plist"
  # Use the same reviewed notes in the release and inside the updater window.
  cat releaseNotes.md >> build/release/releaseNotes.md
  echo 'Signed appcast generated. Publish it only after the release is public.'
else
  echo 'Local test package only: no signed update feed generated.'
fi
