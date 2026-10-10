/// UI 编译冒烟：无 Xcode/Android SDK 的环境下（构建走 CI），
/// 通过把全部页面/组件库链入测试编译，保证类型级错误在本地即可暴露。
/// 这里只做编译与最小构建，不做依赖 FFI 的运行时行为。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qishui_player/core/appearance.dart';
import 'package:qishui_player/core/changelog.dart';
import 'package:qishui_player/main.dart' as globals;
import 'package:qishui_player/ui/pages/appearance_page.dart';
import 'package:qishui_player/ui/pages/mine_page.dart';
import 'package:qishui_player/ui/pages/player_page.dart';
import 'package:qishui_player/ui/pages/ranking_page.dart';
import 'package:qishui_player/ui/pages/settings_page.dart';
import 'package:qishui_player/ui/widgets/color_picker_sheet.dart';
import 'package:qishui_player/ui/widgets/lyrics_style_sheet.dart';
import 'package:qishui_player/ui/widgets/track_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 引用各库的公开符号：让全部新页面/组件都参与测试编译
  test('UI 库符号链入', () {
    expect(PlayerPage, isNotNull);
    expect(SettingsPage, isNotNull);
    expect(MinePage, isNotNull);
    expect(showLyricsStyleSheet, isNotNull);
    expect(showTrackSheet, isNotNull);
    expect(showColorPickerSheet, isNotNull);
  });

  test('更新日志数据与查取', () {
    expect(kChangelog, isNotEmpty);
    final entry = kChangelog.where((e) => e.version == '1.0.0').firstOrNull;
    expect(entry, isNotNull);
    expect(entry!.items, contains(contains('听歌排行')));
  });

  testWidgets('RankingPage / AppearancePage 可构建', (tester) async {
    // widget 测试里平台通道无真实实现，必须挂 mock，否则
    // SharedPreferences 调用会永久等待（平台永不回包）
    SharedPreferences.setMockInitialValues({});
    globals.appearance = await Appearance.load();
    await tester.pumpWidget(const MaterialApp(home: RankingPage()));
    expect(find.text('听歌排行'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: AppearancePage()));
    expect(find.text('个性化外观'), findsOneWidget);
    // 首屏内可见的卡片标题（进度条样式卡片在首屏外，ListView 懒构建）
    expect(find.text('主题色'), findsOneWidget);
  });

  testWidgets('壁纸选色器：打开 → 确认后切到自选色模式', (tester) async {
    SharedPreferences.setMockInitialValues({});
    globals.appearance = await Appearance.load();
    await tester.pumpWidget(const MaterialApp(home: AppearancePage()));
    await tester.ensureVisible(find.text('自定义颜色'));
    await tester.tap(find.text('自定义颜色'));
    await tester.pumpAndSettle();
    // SV 面板 / 色相条（CustomPaint）与十六进制输入已渲染
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.text('确定'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(globals.appearance.wallpaperIsCustom, isTrue);
    expect(globals.appearance.wallpaperCustomColors, hasLength(3));
    // 预览条随模式刷新（旧渐变预设不再出现在外观页）
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
