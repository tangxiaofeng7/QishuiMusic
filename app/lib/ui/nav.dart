import 'package:flutter/material.dart';

/// 首页壳当前选中的底部 Tab（全局，供深层页面切 Tab）。
final ValueNotifier<int> homeTabIndex = ValueNotifier<int>(0);

/// 底部 Tab 下标（首页 0 / 发现 1 / 播放 2 / 我的 3 / 设置 4）。
const int kDiscoverTabIndex = 1;
const int kPlayerTabIndex = 2;
const int kSettingsTabIndex = 4;

/// 打开播放器：关掉压在首页壳上的页面并切到播放 Tab。
/// 播放器从路由页改为常驻 Tab（迷你条随之移除）后，这里是唯一入口；
/// 在任意深层页面点「正在播放的曲目」都能一步回到播放器。
void openPlayerTab(BuildContext context) {
  Navigator.of(context).popUntil((route) => route.isFirst);
  homeTabIndex.value = kPlayerTabIndex;
}
