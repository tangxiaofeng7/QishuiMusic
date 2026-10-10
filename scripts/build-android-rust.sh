#!/usr/bin/env bash
# 编译 Rust 核心（sodam-ffi）为 Android 动态库，产出
# app/android/app/src/main/jniLibs/<abi>/libsodam_ffi.so。
#
# 依赖：rustup、cargo-ndk（cargo install cargo-ndk）、Android NDK
#（环境变量 ANDROID_NDK_HOME 或 ANDROID_NDK_ROOT，或由 flutter 自动装的那个）。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v cargo-ndk >/dev/null 2>&1; then
  echo "错误：需要 cargo-ndk（cargo install cargo-ndk）" >&2
  exit 1
fi

NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$NDK_HOME" ]]; then
  # 常见默认位置兜底
  for candidate in \
    "$HOME/Android/Sdk/ndk/"*/ \
    "${LOCALAPPDATA:-}/Android/Sdk/ndk/"*/ ; do
    if compgen -G "$candidate" >/dev/null; then
      NDK_HOME=$(ls -d "$candidate" | sort -V | tail -1)
      break
    fi
  done
fi
if [[ -n "$NDK_HOME" ]]; then
  export ANDROID_NDK_HOME="$NDK_HOME"
  echo "==> 使用 NDK：$ANDROID_NDK_HOME"
else
  echo "警告：未找到 ANDROID_NDK_HOME/ANDROID_NDK_ROOT，cargo-ndk 可能自己找到。" >&2
fi

OUT="app/android/app/src/main/jniLibs"
mkdir -p "$OUT/arm64-v8a" "$OUT/armeabi-v7a"

echo "==> cargo ndk 编译（arm64-v8a + armeabi-v7a）"
(cd rust/sodam-ffi && cargo ndk \
  --target arm64-v8a \
  --target armeabi-v7a \
  -o "../../$OUT" \
  build --release)

echo "==> 产物："
find "$OUT" -name 'libsodam_ffi.so' -exec ls -lh {} \;
