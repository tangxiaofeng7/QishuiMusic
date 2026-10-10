#!/bin/bash
OLD=/var/mobile/Containers/Data/Application/C95CD4EB-3E4E-4C35-9914-F8BD7158AAC0
echo "--- marker: $([ -f "$OLD/tmp/SODAM_SELFTEST" ] && echo EXISTS || echo GONE) ---"
echo "--- log: $([ -f "$OLD/Documents/sodam-debug.log" ] && echo EXISTS || echo GONE) ---"
ls -la "$OLD/Documents/" "$OLD/tmp/" 2>/dev/null
echo "--- killall exists? ---"
command -v killall
killall -9 Runner 2>&1; echo "killall rc=$?"
sleep 2
uiopen --bundleid com.soda.qishuimusic 2>&1; echo "uiopen rc=$?"
sleep 6
ls -la "$OLD/Documents/" 2>/dev/null
[ -f "$OLD/Documents/sodam-debug.log" ] && head -5 "$OLD/Documents/sodam-debug.log" || echo STILL_NO_LOG
