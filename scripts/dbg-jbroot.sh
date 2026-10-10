#!/bin/bash
JB=/private/var/containers/Bundle/Application/.jbroot-DA5EA0C083C1EA4C/Applications
echo "--- jbroot Applications ---"
ls -la "$JB" 2>/dev/null
echo "--- SodaM.app contents ---"
ls -la "$JB/SodaM.app" 2>/dev/null | head -25
echo "--- its Info.plist id/version ---"
grep -a -A1 -E "CFBundleIdentifier|CFBundleShortVersionString|CFBundleExecutable" "$JB/SodaM.app/Info.plist" 2>/dev/null | head -12
echo "--- my install still there? ---"
ls /private/var/containers/Bundle/Application/e4a33bc1e8bca2c945d1e90406dd1137/ 2>/dev/null
echo "--- uicache -l full soda entries ---"
uicache -l 2>/dev/null | grep -i soda
