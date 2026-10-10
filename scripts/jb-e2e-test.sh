#!/bin/bash
# 在越狱手机上完成一次端到端验证：
#   1. 注入官方汽水 App 的会话 Cookie（免交互登录）
#   2. 放置 SODAM_SELFTEST 标记（启动后自动跑全链路自检）
#   3. 启动 App，等待，读取 sodam-debug.log 摘要
# 用法（Mac 上）: bash scripts/jb-e2e-test.sh <cookie文件> [数据容器UUID]
set -euo pipefail

PHONE=root@10.192.48.219
COOKIE_FILE="${1:?用法: jb-e2e-test.sh <cookie文件> [数据容器UUID]}"
BID="com.soda.qishuimusic"
UUID="${2:-}"

SSH() { sshpass -p woaini520 ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no "$PHONE" "$@"; }

# 1. 找数据容器
if [ -z "$UUID" ]; then
  UUID=$(SSH "grep -rl '$BID' /var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist 2>/dev/null | head -1 | xargs dirname | xargs basename")
fi
echo "==> 数据容器: $UUID"
[ -n "$UUID" ] || { echo "找不到数据容器"; exit 1; }

# 2. 写 cookie 进 NSUserDefaults plist（flutter.* 键）+ 清旧会话键
COOKIE=$(cat "$COOKIE_FILE")
SSH "plutil -replace flutter.cookie -string '$COOKIE' /var/mobile/Containers/Data/Application/$UUID/Library/Preferences/$BID.plist 2>/dev/null || true"

# 3. 自检标记
SSH "mkdir -p /var/mobile/Containers/Data/Application/$UUID/tmp && touch /var/mobile/Containers/Data/Application/$UUID/tmp/SODAM_SELFTEST && chown -R mobile:mobile /var/mobile/Containers/Data/Application/$UUID/tmp"

# 4. 杀掉旧进程并启动
SSH "killall Runner 2>/dev/null || true; sleep 1; uiopen --bundleid $BID"

echo "==> App 已启动，等待自检（60s）…"
sleep 60

# 5. 读日志
SSH "tail -80 /var/mobile/Containers/Data/Application/$UUID/Documents/sodam-debug.log 2>/dev/null || echo NO_LOG"
