#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' info.plist)
buildNumber=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' info.plist)
minimumOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' info.plist)
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
   [[ ! "$buildNumber" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$minimumOS" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo 'Invalid version/build/minimum macOS in info.plist.' >&2
  exit 1
fi
releaseTag=${1:-v$version}
if [[ "$releaseTag" != "v$version" ]]; then
  echo 'Release tag must exactly match v + CFBundleShortVersionString.' >&2
  exit 1
fi
if [[ $# -gt 2 ]] || [[ $# -eq 2 && "$2" != --check-only ]]; then
  echo 'Usage: packageRelease.sh [vMAJOR.MINOR.PATCH [--check-only]]' >&2
  exit 1
fi
if [[ ${2:-} == --check-only ]]; then
  echo "Validated release $releaseTag (build $buildNumber)."
  exit 0
fi

app='build/Xelume Switch.app'
# Package only a freshly built app whose metadata exactly matches the source.
cmp info.plist "$app/Contents/Info.plist"
codesign --verify --strict "$app"
architecture=$(lipo -archs "$app/Contents/MacOS/XelumeSwitch")
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
Xelume Switch $releaseTag (build $buildNumber)

- 安装：打开 DMG，将 Xelume Switch.app 拖入 Applications，然后推出磁盘映像，从“应用程序”打开应用。
- 支持 Apple Silicon（arm64），最低 macOS ${minimumOS}。
- 此包仅使用临时（ad-hoc）签名，未经 Developer ID 签名或 Apple 公证，macOS 可能阻止打开。不是正式公证发行版。
- 目前只兼容已检查版本 26.825.51511 的官方 ChatGPT 客户端及默认文件认证。
- 自动化测试不验证真实账号登录、钥匙串授权或真实额度查询，发布前请人工验收。
- 校验下载文件：将 DMG 与 SHA256SUMS.txt 放在同一目录，运行 shasum -a 256 -c SHA256SUMS.txt。

这是自动生成的 Release 草稿。请补充变更说明并验证安装、菜单和账号切换后再手动发布。
NOTES
printf 'Packaged: build/release/%s\n' "$archive"
