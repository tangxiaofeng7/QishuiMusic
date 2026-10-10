#!/bin/bash
# 远程触发自检：定位数据容器 -> 放 SODAM_SELFTEST 标记 -> 启动 App -> 收日志。
# 用法（本机）: ssh root@192.168.1.75 bash -s < scripts/selftest-remote.sh [等待秒数]
#
# 容器定位坑：mobile_installation 的 bundle->container 映射可能指向旧容器
# （安装脚本自建的新容器会被系统忽略/回收）。所以标记写进所有同 bundle id
# 容器，启动后以「最新的 sodam-debug.log」为准。
BID="com.soda.qishuimusic"
WAIT="${1:-40}"

matches=()
for d in /var/mobile/Containers/Data/Application/*/; do
  grep -q "<string>$BID</string>" \
    "$d/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null \
    && matches+=("${d%/}")
done

# 老容器（系统映射在用的）可能 metadata 已丢——凡有 sodam-debug.log 的也纳入
for d in /var/mobile/Containers/Data/Application/*/; do
  [ -f "${d}Documents/sodam-debug.log" ] && [[ " ${matches[*]} " != *" ${d%/} "* ]] \
    && matches+=("${d%/}")
done
[ ${#matches[@]} -gt 0 ] || { echo "container not found"; exit 1; }

# 冷启动语义：自检只在 main() 里跑，App 若在前台挂着 uiopen 只会切回前台。
killall -9 Runner 2>/dev/null || true
sleep 1

LOG=""
for d in "${matches[@]}"; do
  if [ -f "$d/Documents/sodam-debug.log" ]; then
    LOG="$d/Documents/sodam-debug.log"
    rm -f "$LOG"
  fi
  mkdir -p "$d/tmp"
  touch "$d/tmp/SODAM_SELFTEST"
done
echo "containers: ${matches[*]}"

uiopen --bundleid "$BID"
sleep "$WAIT"

# 重新扫描（App 启动可能新建容器）；取最新的日志
LOG=$(find /var/mobile/Containers/Data/Application -name 'sodam-debug.log' \
  -exec stat -c '%Y %n' {} \; 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
if [ -z "$LOG" ]; then
  echo "(no log yet — app may have failed to launch)"
  exit 1
fi
echo "LOG=$LOG"
grep -v 'stack:' "$LOG"
