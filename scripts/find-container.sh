#!/bin/bash
# 列出最近活跃的数据容器及 bundle id（诊断容器定位）。
for d in /var/mobile/Containers/Data/Application/*/; do
  id=$(/var/jb/usr/bin/plutil -extract MCMMetadataIdentifier raw \
    "$d/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null || echo '?')
  mtime=$(stat -c '%y' "$d" 2>/dev/null | cut -c1-16)
  log="$([ -f "${d}Documents/sodam-debug.log" ] && echo LOG)"
  echo "$mtime $id $log ${d%/}"
done | sort -r | head -15
