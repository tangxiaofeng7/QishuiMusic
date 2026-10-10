#!/bin/bash
BID="com.soda.qishuimusic"
APP=$(uicache -l 2>/dev/null | grep "$BID" | awk '{print $3}')
echo "registered bundle: $APP"
[ -z "$APP" ] && { echo "NOT REGISTERED"; exit 1; }

echo "--- frameworks ---"
ls "$APP/Frameworks/" | head -20
echo "--- old container state ---"
OLD=/var/mobile/Containers/Data/Application/C95CD4EB-3E4E-4C35-9914-F8BD7158AAC0
stat -c '%y %n' "$OLD/Documents/sodam-debug.log" 2>/dev/null || echo "no old log"
ls "$OLD/tmp/" 2>/dev/null

echo "--- uicache refresh + launch ---"
uicache -p "$APP"
uiopen --bundleid "$BID"
sleep 3
echo "--- processes ---"
for p in /var/jb/usr/bin/ps /usr/bin/ps /bin/ps; do
  [ -x "$p" ] && "$p" aux | grep -i "[R]unner" && break
done || true
ls /proc/ 2>/dev/null | head -1 >/dev/null && grep -l Runner /proc/*/cmdline 2>/dev/null | head -3
echo "--- new logs anywhere (15s window) ---"
sleep 12
find /var/mobile/Containers/Data/Application -name 'sodam-debug.log' -exec stat -c '%y %n' {} \; 2>/dev/null
find /var/mobile/Containers/Data/Application -maxdepth 1 -newermt '-2 minutes' 2>/dev/null
echo "--- crash ---"
ls -lt /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | head -5
