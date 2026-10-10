#!/bin/bash
# 把新构建同步进 TrollStoreLite 抢注的 .jbroot/SodaM.app 并全量伪签 + 注册。
set -e
BID="com.soda.qishuimusic"
JBROOT_APP=/private/var/containers/Bundle/Application/.jbroot-DA5EA0C083C1EA4C/Applications/SodaM.app
SRC=/private/var/containers/Bundle/Application/e4a33bc1e8bca2c945d1e90406dd1137/Runner.app
LDID=$(command -v ldid || echo /var/jb/usr/bin/ldid)

# 同步（保留 .jbroot 符号链接是 TrollStore 系统应用标记）
find "$JBROOT_APP" -mindepth 1 -maxdepth 1 ! -name '.jbroot' -exec rm -rf {} +
cp -R "$SRC/." "$JBROOT_APP/"

"$LDID" -S "$JBROOT_APP/Runner"
for fw in "$JBROOT_APP/Frameworks"/*.framework; do
  name=$(basename "$fw" .framework)
  [ -f "$fw/$name" ] && "$LDID" -S "$fw/$name"
done
find "$JBROOT_APP" -name '*.dylib' -type f -exec "$LDID" -S {} \; 2>/dev/null || true
chmod -R 755 "$JBROOT_APP"

uicache -p "$JBROOT_APP"
echo "SYNCED+REGISTERED"
uicache -l | grep -i soda
