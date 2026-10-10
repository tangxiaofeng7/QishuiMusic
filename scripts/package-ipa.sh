#!/usr/bin/env bash
# 把 flutter build ipa --no-codesign 的 xcarchive 打包成无签名 IPA。
# 产物：QishuiMusic-unsigned.ipa —— 可直接用 TrollStore 安装，或交给
# Sideloadly / AltStore / 全能签 / 爱思助手 等自签工具。
set -euo pipefail

cd "$(dirname "$0")/../app"

ARCHIVE="build/ios/archive/Runner.xcarchive"
if [[ ! -d "$ARCHIVE/Products/Applications/Runner.app" ]]; then
  echo "错误：找不到 $ARCHIVE/Products/Applications/Runner.app，先运行："
  echo "  flutter build ipa --no-codesign"
  exit 1
fi

OUT_DIR="build/ios/ipa-unsigned"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/Payload"
cp -R "$ARCHIVE/Products/Applications/Runner.app" "$OUT_DIR/Payload/"

# 注入 Rust 动态框架（build-ios-rust.sh 产出；Dart 按绝对路径 dlopen）
FW_SRC="ios/Rust/sodam_ffi.framework"
if [ -d "$FW_SRC" ]; then
  rm -rf "$OUT_DIR/Payload/Runner.app/Frameworks/sodam_ffi.framework"
  cp -R "$FW_SRC" "$OUT_DIR/Payload/Runner.app/Frameworks/"
  echo "==> 已注入 sodam_ffi.framework"
else
  echo "警告：ios/Rust/sodam_ffi.framework 不存在（先跑 scripts/build-ios-rust.sh）" >&2
fi

cd "$OUT_DIR"
zip -qry ../QishuiMusic-unsigned.ipa Payload
cd - >/dev/null

echo "==> 产出：$OUT_DIR/../QishuiMusic-unsigned.ipa"
# head 会提前关管道让 unzip 收到 SIGPIPE（141），在 set -o pipefail 的调用方
# （含 GitHub Actions 默认 shell）里会误判整个打包失败——这里显式兜底。
unzip -l "$OUT_DIR/../QishuiMusic-unsigned.ipa" | head -8 || true
