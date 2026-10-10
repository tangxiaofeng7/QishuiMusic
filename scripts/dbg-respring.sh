#!/bin/bash
OLD=/var/mobile/Containers/Data/Application/C95CD4EB-3E4E-4C35-9914-F8BD7158AAC0
mkdir -p "$OLD/tmp"; touch "$OLD/tmp/SODAM_SELFTEST"
echo "marker set: $([ -f "$OLD/tmp/SODAM_SELFTEST" ] && echo YES)"
echo "--- respring ---"
killall -9 SpringBoard 2>&1 || true
sleep 25
echo "--- launch after respring ---"
uiopen --bundleid com.soda.qishuimusic 2>&1
sleep 8
[ -f "$OLD/Documents/sodam-debug.log" ] && head -8 "$OLD/Documents/sodam-debug.log" || echo STILL_NO_LOG
