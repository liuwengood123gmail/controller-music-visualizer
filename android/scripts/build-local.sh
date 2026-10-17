#!/usr/bin/env bash
# 在 Mac 上编译 APK 并装到用 USB 连着的手机 / 平板（不用等 CI）。
#
# 需要（装一次）：
#   brew install openjdk@21 swiftly && brew install --cask android-commandlinetools
#   swiftly init --no-modify-profile --skip-install && swiftly install 6.3.3
#   swift sdk install …swift-6.3.3-RELEASE_android.artifactbundle.tar.gz（与 CI 同一个包和校验码）
#   sdkmanager --sdk_root=~/Library/Android/sdk "platforms;android-36" "platforms;android-37.2" "ndk;27.3.13750724" "build-tools;36.0.0" platform-tools
#   然后跑一次 Swift SDK 里的 setup-android-sdk.sh 关联 NDK
# 签名：~/.config/cmv-android-signing 里有预览版密钥时用它（和 CI 同一把，可以互相覆盖安装），否则 debug 签名。
#
# 用法：android/scripts/build-local.sh            编译 + 安装
#       android/scripts/build-local.sh --no-install
set -euo pipefail
cd "$(dirname "$0")/.."   # android/

export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
export ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
export ANDROID_NDK_HOME=${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/27.3.13750724}
export SWIFT_SDKS_DIR=${SWIFT_SDKS_DIR:-$HOME/Library/org.swift.swiftpm/swift-sdks}
# 必须是与 Swift SDK for Android 同版本的 swift.org 工具链（Xcode 自带的 swift 不行）
export SWIFT=${SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}

KEYS=$HOME/.config/cmv-android-signing
if [[ -f $KEYS/preview.p12 && -f $KEYS/password.txt ]]; then
    export CV_KEYSTORE=$KEYS/preview.p12
    CV_KEYSTORE_PASSWORD=$(tr -d '\n' < "$KEYS/password.txt")
    export CV_KEYSTORE_PASSWORD
fi

scripts/build-swift-android.sh > /dev/null
./gradlew -q :app:assembleRelease
APK=app/build/outputs/apk/release/app-release.apk
echo "✓ $APK"

if [[ "${1:-}" != "--no-install" ]]; then
    "$ANDROID_HOME/platform-tools/adb" install -r "$APK"
fi
