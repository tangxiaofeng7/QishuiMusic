#!/bin/bash
# 本地构建 + 越狱机一键部署（Xcode 本地编译优先的工作流）。
#
# 流程：Rust iOS 交叉编译 → flutter ipa（无签名）→ 打包 → 手机经
# TrollStoreLite（apple-magnifier://install）安装，用户可自行卸载。
# 用法：bash scripts/build-and-deploy-ios.sh [--no-build]
#   --no-build  跳过编译，仅部署 app/build/ios/QishuiMusic-unsigned.ipa
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHONE="${SODAM_PHONE:-root@10.192.48.219}"
PHONE_PW="${SODAM_PHONE_PW:-woaini520}"
BID="com.soda.qishuimusic"
IPA="$ROOT/app/build/ios/QishuiMusic-unsigned.ipa"
HTTP_PORT="${SODAM_HTTP_PORT:-8300}"
HTTP_IP="${SODAM_HTTP_IP:-$(ipconfig getifaddr en0 || ipconfig getifaddr en1)}"

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

SSH() { sshpass -p "$PHONE_PW" ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 "$PHONE" "$@"; }

if [ "${1:-}" != "--no-build" ]; then
  echo "==> [1/4] Rust iOS 交叉编译"
  (cd "$ROOT" && bash scripts/build-ios-rust.sh)

  echo "==> [2/4] Flutter IPA（无签名）"
  APP_VERSION=$(awk '/^version:/{print $2; exit}' "$ROOT/app/pubspec.yaml")
  (cd "$ROOT/app" && flutter build ipa --no-codesign --release \
    --dart-define=APP_VERSION="$APP_VERSION")

  echo "==> [3/4] 打包无签名 IPA"
  (cd "$ROOT" && bash scripts/package-ipa.sh)
fi

echo "==> [4/4] TrollStoreLite 安装 ${PHONE}"
ls -lh "$IPA"
[ -n "$HTTP_IP" ] || { echo "拿不到本机局域网 IP（用 SODAM_HTTP_IP 手动指定）" >&2; exit 1; }

# 本机起临时 HTTP 服务供手机拉取 IPA
( cd "$ROOT/app/build/ios" && exec python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 ) \
  >/tmp/qishui-http.log 2>&1 &
HTTP_PID=$!
trap 'kill "$HTTP_PID" 2>/dev/null || true' EXIT
sleep 1

# 拉起 TrollStoreLite 安装弹窗（手机上需手动点一次「安装」）
SSH "killall -9 Runner 2>/dev/null; uiopen 'apple-magnifier://install?url=http://$HTTP_IP:$HTTP_PORT/QishuiMusic-unsigned.ipa'" || true
echo "==> 已在手机上拉起 TrollStoreLite 安装窗口，请在手机上点「安装」…"

# 轮询等待注册完成（最长 120s）
INSTALLED=""
for i in $(seq 1 60); do
  if SSH "uicache -l 2>/dev/null" | grep -q "^$BID :"; then
    INSTALLED=1
    break
  fi
  sleep 2
done
if [ -z "$INSTALLED" ]; then
  echo "等待安装超时：确认手机上已点击「安装」，或检查 http://$HTTP_IP:$HTTP_PORT 可达" >&2
  exit 1
fi
echo "==> TrollStoreLite 安装完成。启动验证："
echo "    ssh $PHONE 'uiopen --bundleid $BID'"
echo "    日志：bash scripts/read-app-log.sh（或直接找最新的 sodam-debug.log）"
