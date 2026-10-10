#!/bin/bash
D=/var/mobile/Containers/Data/Application/323748ecd157348ce2e0d2a908960701
echo "--- filename check ---"
ls -la "$D"
echo "--- plutil -p ---"
/var/jb/usr/bin/plutil -p "$D/.com.apple.mobile_container_manager.metadata.plist"
echo "rc=$?"
echo "--- extract ---"
/var/jb/usr/bin/plutil -extract MCMMetadataIdentifier raw "$D/.com.apple.mobile_container_manager.metadata.plist"
echo "rc=$?"
echo "--- cat ---"
cat "$D/.com.apple.mobile_container_manager.metadata.plist"
