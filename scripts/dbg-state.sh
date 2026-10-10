#!/bin/bash
echo "--- Runner processes ---"
ps aux | grep -i "[R]unner" || echo "(none)"
echo "--- container 47449b60 (chosen) ---"
find /var/mobile/Containers/Data/Application/47449b60992abd33b933f20ef7208d39 -maxdepth 2 2>/dev/null
echo "--- container 323748ec ---"
find /var/mobile/Containers/Data/Application/323748ecd157348ce2e0d2a908960701 -maxdepth 2 2>/dev/null
echo "--- all recent sodam logs ---"
find /var/mobile/Containers/Data/Application -name 'sodam-debug.log' -newer /var/mobile/SodaM-unsigned.ipa 2>/dev/null
echo "--- crash reports (last 10min) ---"
ls -lt /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | head -8
