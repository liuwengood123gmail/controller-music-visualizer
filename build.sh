#!/bin/bash
# 编译并打包成 build/ControllerMusicVisualizer.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/ControllerMusicVisualizer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ControllerMusicVisualizer "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
# 有 Apple Development 证书就用它签名（系统录音权限在重新编译后仍然保留），否则临时签名
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"

echo "✓ 已生成 $APP"
