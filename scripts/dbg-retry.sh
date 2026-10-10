#!/bin/bash
BID="com.soda.qishuimusic"
OLD=/var/mobile/Containers/Data/Application/C95CD4EB-3E4E-4C35-9914-F8BD7158AAC0
APP=$(uicache -l 2>/dev/null | grep "$BID" | awk '{print $3}')
echo "bundle: $APP"
echo "--- exact retry of working sequence ---"
uicache -p "$APP" 2>&1
sleep 2
uiopen --bundleid "$BID" 2>&1
sleep 8
[ -f "$OLD/Documents/sodam-debug.log" ] && head -8 "$OLD/Documents/sodam-debug.log" || echo STILL_NO_LOG
echo "--- crash dirs ---"
for dir in /var/mobile/Library/Logs/CrashReporter /var/logs/CrashReporter /var/root/Library/Logs/CrashReporter; do
  ls -lt "$dir" 2>/dev/null | head -4
done
echo "--- panic / system log tail ---"
ls -lt /var/mobile/Library/Logs/ 2>/dev/null | head -6
