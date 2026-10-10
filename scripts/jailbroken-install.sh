#!/bin/bash
# RootHide 越狱手机上手动安装 SodaM（解包 + 全量 ldid 伪签 + uicache 注册）。
# 用法（手机上）: bash manual_install.sh [ipa路径]  （默认 /var/mobile/SodaM-unsigned.ipa）
#
# 说明：TrollStore 的 install-url 也可以装（uiopen "apple-magnifier://install?url=http://<pc>:8080/SodaM-unsigned.ipa"），
# 但那需要在手机上点一次「安装」；本脚本全程 SSH 自动化，适合调试迭代。
set -e
BID="com.soda.qishuimusic"
IPA="${1:-/var/mobile/SodaM-unsigned.ipa}"
WORK="/tmp/sodam_install"
BUNDLE_ROOT="/var/containers/Bundle/Application"
LDID=$(command -v ldid || echo /var/jb/usr/bin/ldid)

uuid() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

rm -rf "$WORK"; mkdir -p "$WORK"
cd "$WORK"
unzip -q "$IPA"

# 卸掉旧安装（重复调试用；也清掉历史误装位置）。
# 注意 RootHide 的 plutil 不认 -extract，改用 grep 匹配 plist 内容
# （XML 与二进制 plist 里的 bundle id 字符串都是明文字节，均可命中）。
rm -rf "$BUNDLE_ROOT/Runner.app"
for d in "$BUNDLE_ROOT"/*/; do
  if [ -f "$d/Runner.app/Info.plist" ] && grep -aq "$BID" "$d/Runner.app/Info.plist"; then
    echo "remove old: $d"
    rm -rf "$d"
  fi
done

UUID=$(uuid)
[ -n "$UUID" ] || { echo "uuid gen failed"; exit 1; }
APPDIR="$BUNDLE_ROOT/$UUID"
mkdir -p "$APPDIR"
mv Payload/Runner.app "$APPDIR/"
APP="$APPDIR/Runner.app"

# 主程序 + 每个 framework 主二进制 + 所有 dylib 全量伪签
# （框架清单不能写死：插件更新会引入新 framework，漏签即 dyld 拒载）
"$LDID" -S "$APP/Runner"
for fw in "$APP/Frameworks"/*.framework; do
  name=$(basename "$fw" .framework)
  if [ -f "$fw/$name" ]; then
    "$LDID" -S "$fw/$name"
    echo "signed: $name"
  fi
done
find "$APP" -name '*.dylib' -type f -exec "$LDID" -S {} \; 2>/dev/null || true

# 数据容器（系统随后会按 bundle id 关联/自建）
DATA_UUID=$(uuid)
[ -n "$DATA_UUID" ] || { echo "data uuid gen failed"; exit 1; }
DATA="/var/mobile/Containers/Data/Application/$DATA_UUID"
mkdir -p "$DATA"
cat > "$DATA/.com.apple.mobile_container_manager.metadata.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>MCMMetadataIdentifier</key>
	<string>$BID</string>
	<key>MCMMetadataPID</key>
	<integer>99</integer>
	<key>MCMMetadata_InitialStatePlist</key>
	<dict/>
</dict>
</plist>
EOF
chown -R mobile:mobile "$DATA"
chown -R root:wheel "$APPDIR" 2>/dev/null || chown -R root:wheel "$APPDIR"

uicache -p "$APP"
echo "INSTALL_DONE uuid=$UUID"
echo "启动: uiopen --bundleid $BID"
echo "日志: bash read_app_log.sh"
