#!/bin/bash
# RootHide 越狱机「系统级 App」安装：装进 /var/jb/Applications（无沙盒，
# 不受国行 iOS「无线数据」权限限制——容器型 App 的网络会被 NECP 全量拒绝，
# DNS EAI_NONAME + No route to host，见 deploy_verify 自检诊断）。
# 用法（手机上）: bash jailbroken-install-sysapp.sh [ipa路径]
set -e
BID="com.soda.qishuimusic"
IPA="${1:-/var/mobile/SodaM-unsigned.ipa}"
WORK="/tmp/sodam_install"
LDID=$(command -v ldid || echo /var/jb/usr/bin/ldid)
BUNDLE_ROOT="/var/containers/Bundle/Application"
DEST="/var/jb/Applications/SodaM.app"

rm -rf "$WORK"; mkdir -p "$WORK"
cd "$WORK"
unzip -q "$IPA"

# 清掉旧的容器型安装（同 bundle id 只留一个）
for d in "$BUNDLE_ROOT"/*/; do
  if [ -f "$d/Runner.app/Info.plist" ]; then
    old=$(/var/jb/usr/bin/plutil -extract CFBundleIdentifier raw "$d/Runner.app/Info.plist" 2>/dev/null || true)
    if [ "$old" = "$BID" ]; then
      echo "remove container install: $d"
      rm -rf "$d"
    fi
  fi
done
rm -rf "$DEST"

mv Payload/Runner.app "$DEST"

# 主程序 + framework 主二进制 + 所有 dylib 全量伪签
"$LDID" -S "$DEST/Runner"
for fw in "$DEST/Frameworks"/*.framework; do
  name=$(basename "$fw" .framework)
  if [ -f "$fw/$name" ]; then
    "$LDID" -S "$fw/$name"
    echo "signed: $name"
  fi
done
find "$DEST" -name '*.dylib' -type f -exec "$LDID" -S {} \; 2>/dev/null || true

chown -R root:wheel /var/jb/Applications/SodaM.app

uicache -p "$DEST"
echo "INSTALL_DONE sysapp=$DEST"
echo "启动: uiopen --bundleid $BID"
