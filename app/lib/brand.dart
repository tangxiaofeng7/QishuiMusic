/// 品牌定制点
/// 说明：iOS 桌面图标与显示名在 app/ios/Runner/Info.plist（CFBundleDisplayName）
/// 与 Assets.xcassets，Android 在 app/android/app/src/main/AndroidManifest.xml
/// 的 android:label——源码内的品牌值以这里为单一来源。

library;

import 'package:flutter/material.dart';

/// App 名称（MaterialApp 标题等）。
const String kAppName = '汽水播放器';

/// 品牌主色（Material 3 seedColor，深浅色同源）。
const Color kSeedColor = Color(0xFF3AAFA9);

/// 版本号：构建时注入（`--dart-define=APP_VERSION=<pubspec version>`），
/// 本地直接 flutter run / CI 未注入时显示 dev。
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);

/// 源码仓库（关于页展示）。
const String kRepoUrl = 'https://github.com/tangxiaofeng7/qishuimusic';

/// 用户交流群（设置页「交流群」跳转，Telegram 邀请链接）。
const String kCommunityUrl = 'https://t.me/lvsec777';
