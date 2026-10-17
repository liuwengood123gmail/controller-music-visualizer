#!/usr/bin/env bash
# 把 Swift 核心（ControllerCAPI）交叉编译成 Android 的 .so，连同用到的 Swift 运行库一起放进
# engine/src/main/jniLibs/<abi>/，供 Gradle 打包。
#
# 需要：Swift 6.3+ 工具链、对应版本的 Swift SDK for Android（`swift sdk install …_android.artifactbundle`，
# 并按 SDK 里的 scripts/setup-android-sdk.sh 关联 NDK）、Android NDK r27+（ANDROID_NDK_HOME）。
# 环境变量：SWIFT（swift 可执行文件，默认 swift）、API（默认 28）、
#           ABIS（默认 arm64-v8a；模拟器测试加 x86_64，例如 ABIS="arm64-v8a x86_64"）
set -euo pipefail
cd "$(dirname "$0")/../.."          # 仓库根目录（Package.swift 所在）
SWIFT=${SWIFT:-swift}
API=${API:-28}
ABIS=${ABIS:-arm64-v8a}
: "${ANDROID_NDK_HOME:?需要 ANDROID_NDK_HOME}"
READELF=$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-readelf | head -1)

# Swift 运行库所在目录：SDK 包里的 swift-resources/usr/lib/swift-<arch>/android
SDK_LIB=$(find ${SWIFT_SDKS_DIR:-} "$HOME/.swiftpm" "$HOME/.config/swiftpm" "$HOME/.local/share/swiftpm" \
          -path "*android*swift-resources/usr/lib" -type d 2>/dev/null | head -1 || true)
[[ -d "$SDK_LIB" ]] || { echo "找不到 Swift SDK for Android（swift sdk install …）"; exit 1; }

for ABI in $ABIS; do
    case $ABI in
        arm64-v8a) ARCH=aarch64; NDK_TRIPLE=aarch64-linux-android ;;
        x86_64) ARCH=x86_64; NDK_TRIPLE=x86_64-linux-android ;;
        *) echo "不支持的 ABI $ABI"; exit 1 ;;
    esac
    TRIPLE=$ARCH-unknown-linux-android$API
    "$SWIFT" build --swift-sdk "$TRIPLE" -c release --product ControllerCAPI --scratch-path ".build-android/$ABI"

    OUT=android/engine/src/main/jniLibs/$ABI
    rm -rf "$OUT"; mkdir -p "$OUT"
    cp ".build-android/$ABI/release/libControllerCAPI.so" "$OUT/"
    LIBDIR="$SDK_LIB/swift-$ARCH/android"
    CXXLIB=$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/$NDK_TRIPLE/libc++_shared.so | head -1)

    # 按 NEEDED 递归拷贝（系统库 libc / libm / libdl / liblog 不用带）
    queue=(libControllerCAPI.so)
    while ((${#queue[@]})); do
        lib=${queue[0]}; queue=("${queue[@]:1}")
        for dep in $("$READELF" -d "$OUT/$lib" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
            [[ -f "$OUT/$dep" ]] && continue
            if [[ -f "$LIBDIR/$dep" ]]; then cp "$LIBDIR/$dep" "$OUT/"; queue+=("$dep")
            elif [[ "$dep" == libc++_shared.so ]]; then cp "$CXXLIB" "$OUT/"
            fi
        done
    done
    ls -la "$OUT"
done
