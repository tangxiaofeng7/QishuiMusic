#!/usr/bin/env bash
# 编译 Rust 核心（sodam-ffi）为 iOS 静态库，产出 app/ios/Rust/libsodam_ffi.a。
# 只能在 macOS 上运行（需要 Xcode 的 Apple SDK）。
#
# 用法：
#   ./scripts/build-ios-rust.sh            # 真机 arm64（打包 IPA 用）
#   ./scripts/build-ios-rust.sh --sim      # 额外编译模拟器 arm64/x86_64 到 build 目录
set -euo pipefail

cd "$(dirname "$0")/.."

TARGET_DEVICE="aarch64-apple-ios"
OUT_DIR="app/ios/Rust"
mkdir -p "$OUT_DIR"

if ! command -v rustup >/dev/null 2>&1; then
  echo "错误：需要 rustup（https://rustup.rs）" >&2
  exit 1
fi

echo "==> 安装 Rust 目标：$TARGET_DEVICE"
rustup target add "$TARGET_DEVICE"

echo "==> cargo build --release --target $TARGET_DEVICE"
(cd rust/sodam-ffi && cargo build --release --target "$TARGET_DEVICE")

cp "rust/sodam-ffi/target/$TARGET_DEVICE/release/libsodam_ffi.a" "$OUT_DIR/"

# 组装独立动态框架：package-ipa.sh 会把它注入 Runner.app/Frameworks/，
# Dart 按绝对路径 dlopen（见 app/lib/core/ffi.dart）。
# 不再依赖把符号链进 App.framework——Flutter 的 App 组装对注入符号
# 会做 dead-strip，dlsym 拿不到。
FW="$OUT_DIR/sodam_ffi.framework"
rm -rf "$FW"
mkdir -p "$FW"
cp "rust/sodam-ffi/target/$TARGET_DEVICE/release/libsodam_ffi.dylib" "$FW/sodam_ffi"
cat > "$FW/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>sodam_ffi</string>
	<key>CFBundleIdentifier</key>
	<string>com.soda.qishuimusic.ffi</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>sodam_ffi</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>MinimumOSVersion</key>
	<string>13.0</string>
</dict>
</plist>
PLIST
echo "==> 已产出 $OUT_DIR/libsodam_ffi.a 与 $FW"

if [[ "${1:-}" == "--sim" ]]; then
  for target in aarch64-apple-ios-sim x86_64-apple-ios; do
    rustup target add "$target"
    (cd rust/sodam-ffi && cargo build --release --target "$target")
  done
  echo "==> 模拟器产物（手动联调用）："
  ls -lh rust/sodam-ffi/target/aarch64-apple-ios-sim/release/libsodam_ffi.a \
     rust/sodam-ffi/target/x86_64-apple-ios/release/libsodam_ffi.a 2>/dev/null || true
fi
