#!/bin/bash
# 编译并打包成 build/ControllerMusicVisualizer.app
# 用法：./build.sh            只打包
#       ./build.sh --install  打包并安装到「应用程序」（/Applications/Controller Music Visualizer.app）
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/ControllerMusicVisualizer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ControllerMusicVisualizer "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # 图标由 tools/make-icon.swift 生成
# 有 Apple Development 证书就用它签名（系统录音权限在重新编译后仍然保留），否则临时签名
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"

echo "✓ 已生成 $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/Controller Music Visualizer.app"
    pkill -x ControllerMusicVisualizer 2>/dev/null || true   # 正在运行的旧版本先退出
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    # 让访达 / 启动台立即显示新图标
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
    touch "$DEST"
    echo "✓ 已安装到 $DEST"
fi
