#!/usr/bin/env bash
# 模拟器冒烟测试（CI 用）：① 引擎模块的 JNI 测试；② 安装 App、启动，确认原生库能加载、没有崩溃；
# ③ 用调试入口让引擎开始 / 停止一次（没有手柄时应当报「没有找到手柄」而不是崩溃）
set -euo pipefail
cd "$(dirname "$0")/.."
./gradlew --no-daemon -Pcv.abis=arm64-v8a,x86_64 :engine:connectedDebugAndroidTest

adb install -r -g app/build/outputs/apk/debug/app-debug.apk
adb logcat -c
adb shell am start -W -n app.cmv/.MainActivity
sleep 8
svc() { adb shell am start-foreground-service -n app.cmv/app.cmv.engine.android.EngineService --es cmd "$1" 2>&1 | tee /dev/stderr | grep -q "^Error" && { echo "debug entry rejected"; exit 1; } || true; }
svc start
sleep 3
svc stop
sleep 2
adb logcat -d -s cv-engine cv-native cv-app AndroidRuntime | tail -60
if adb logcat -d | grep -E "FATAL EXCEPTION|UnsatisfiedLinkError|signal 11|Fatal signal" ; then
    echo "App crashed"; exit 1
fi
adb shell pidof app.cmv > /dev/null || { echo "App is not running"; exit 1; }
adb logcat -d -s cv-engine | grep -q "debug command: start" || { echo "debug command did not reach the engine"; exit 1; }
echo "Smoke test OK"
