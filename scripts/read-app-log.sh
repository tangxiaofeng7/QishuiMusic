#!/bin/bash
# 读取 SodaM 在越狱手机上的调试日志（Documents/sodam-debug.log）
for d in /var/mobile/Containers/Data/Application/*/; do
  if [ -f "$d/Documents/sodam-debug.log" ]; then
    echo "=== ${d} ==="
    cat "$d/Documents/sodam-debug.log"
  fi
done
if [ -z "$(find /var/mobile/Containers/Data/Application -maxdepth 3 -name sodam-debug.log 2>/dev/null)" ]; then
  echo "NO_LOG_FILE"
fi
