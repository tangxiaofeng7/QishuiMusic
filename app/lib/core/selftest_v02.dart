/// v0.2 迁移功能（借鉴 Beans-Music）的真机专项验证：
/// 数据层往返（外观持久化 / 备份 / 听歌排行 / 插队 / 更新日志）
/// + 活体 UI 挂载（播放页个性化组合实时切换、外观页 / 排行页 /
/// 歌词样式底单渲染，FlutterError 计数捕获渲染异常）。
///
/// 由 selftest.dart 在核心链路自检后调用：此时已有曲目在播、
/// navigator 与首页壳均已挂载，可直接驱动真实 UI。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../brand.dart';
import '../ui/nav.dart';
import '../ui/pages/appearance_page.dart';
import '../ui/pages/ranking_page.dart';
import '../ui/widgets/cover.dart';
import '../ui/widgets/lyrics_style_sheet.dart';
import 'appearance.dart';
import 'changelog.dart';
import 'logging.dart';
import 'models.dart';
import 'play_stats.dart';
import 'player.dart';
import 'signer_bridge.dart';

/// 标准 1×1 透明 PNG（壁纸文件链路验证用）。
const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

Future<void> runV02FeatureChecks(
  PlayerController player,
  Appearance appearance,
  Future<void> Function(String name, Future<void> Function() body) step,
) async {
  // ---- 数据层 ----

  await step('v02.appearancePersist', () async {
    appearance
      ..setAccent(followCover: false, color: 0xFF3D7BE8)
      ..updateLyrics(
        fontSize: 24,
        lineSpacing: 1.6,
        customColors: true,
        baseColor: 0xFFE0E0E0,
        highlightColor: 0xFFE8547C,
        glow: true,
        tilt: true,
      )
      ..setProgressBar(ProgressBarStyle.wave)
      ..setWallpaper('gradient:sakura')
      ..reorderPlayerActions(0, 1); // queue 挪到第二位
    // 独立重载实例验证持久化（SharedPreferences 真实落盘）
    final reloaded = await Appearance.load();
    if (reloaded.accentColor.toARGB32() != 0xFF3D7BE8) {
      throw 'accent 未持久化';
    }
    if (reloaded.lyricFontSize != 24 ||
        reloaded.lyricLineSpacing != 1.6 ||
        !reloaded.lyricCustomColors ||
        !reloaded.lyricGlow ||
        !reloaded.lyricTilt) {
      throw '歌词样式未持久化';
    }
    if (reloaded.progressBar != ProgressBarStyle.wave) throw '进度条未持久化';
    if (reloaded.wallpaper != 'gradient:sakura') throw '壁纸未持久化';
    // 自选色模式（独立覆盖 gradient 验证持久化与渐变派生）
    appearance.setWallpaperColor(0xFF89E0D9);
    final reloadedColor = await Appearance.load();
    if (reloadedColor.wallpaper != 'custom' ||
        reloadedColor.wallpaperColor.toARGB32() != 0xFF89E0D9) {
      throw '自定义壁纸色未持久化';
    }
    final customColors = reloadedColor.wallpaperCustomColors;
    if (customColors == null || customColors.length != 3) {
      throw '自定义壁纸渐变派生异常';
    }
    if (reloaded.playerActions.first != 'speed') {
      throw '快捷按钮排序未持久化 (${reloaded.playerActions.first})';
    }
    appLog('selftest: appearance 全量持久化 ✓');
  });

  await step('v02.backupRoundtrip', () async {
    final map = appearance.toBackupMap();
    final json = jsonEncode(map);
    final restored = await Appearance.load();
    restored.applyBackupMap(jsonDecode(json) as Map<String, dynamic>);
    if (restored.accentColor.toARGB32() != appearance.accentColor.toARGB32()) {
      throw '备份往返 accent 不一致';
    }
    if (restored.playerActions.length != appearance.playerActions.length) {
      throw '备份往返 actions 不一致';
    }
    if (restored.lyricFontSize != appearance.lyricFontSize) {
      throw '备份往返歌词字号不一致';
    }
    if (restored.wallpaper != appearance.wallpaper ||
        restored.wallpaperColor.toARGB32() !=
            appearance.wallpaperColor.toARGB32()) {
      throw '备份往返壁纸设置不一致';
    }
    // 非法/缺字段输入容错（不应抛错、不应清空动作）
    restored.applyBackupMap(const <String, dynamic>{
      'playerActions': ['不存在'],
    });
    if (restored.playerActions.isEmpty) throw '未知动作不应清空列表';
    appLog('selftest: 备份导出/导入往返 + 容错 ✓');
  });

  await step('v02.playStats', () async {
    await PlayStats.clear();
    const a = Track(id: 'selftest-a', title: '自检A', artist: '测试', album: '');
    const b = Track(id: 'selftest-b', title: '自检B', artist: '测试', album: '');
    await PlayStats.record(a);
    await PlayStats.record(a);
    await PlayStats.record(b);
    final week = await PlayStats.top(weekly: true);
    if (week.isEmpty ||
        week.first.track.id != 'selftest-a' ||
        week.first.week != 2) {
      throw '周榜计数错误: '
          '${week.map((e) => '${e.track.id}:${e.week}').join(',')}';
    }
    final total = await PlayStats.top();
    if (total.length != 2 || total.first.total != 2) {
      throw '总榜计数错误: '
          '${total.map((e) => '${e.track.id}:${e.total}').join(',')}';
    }
    appLog('selftest: playStats 记数/周榜/总榜 ✓（榜单页数据保留供 UI 步骤用）');
  });

  await step('v02.insertNext', () async {
    final before = player.trackQueue;
    if (before.length < 2) throw '队列曲目不足（前置播放步骤异常）';
    // 队内已有曲：挪到当前之后
    final target = before.last;
    await player.insertNext(target);
    final after = player.trackQueue;
    if (after[player.index + 1].id != target.id) {
      throw '挪位后下一首不是目标曲 (idx=${player.index}, '
          'next=${after[player.index + 1].id})';
    }
    // 队外新曲：插入当前之后、队列 +1
    const fresh = Track(
        id: 'selftest-next', title: '插队曲', artist: '测试', album: '');
    await player.insertNext(fresh);
    final after2 = player.trackQueue;
    if (after2[player.index + 1].id != 'selftest-next') throw '新曲插队失败';
    if (after2.length != after.length + 1) throw '插队应使队列 +1';
    // 当前曲插队 = 无操作
    final current = player.currentTrack!;
    await player.insertNext(current);
    if (player.trackQueue.length != after2.length) throw '当前曲插队应无效';
    // 移除测试曲恢复现场
    await player.removeAt(
        after2.indexWhere((item) => item.id == 'selftest-next'));
    appLog('selftest: insertNext 挪位/插队/去重 ✓（队列 '
        '${player.trackQueue.length} 首）');
  });

  await step('v02.changelog', () async {
    final entry =
        kChangelog.where((entry) => entry.version == kAppVersion).firstOrNull;
    if (entry == null) throw '当前版本 $kAppVersion 无更新日志条目';
    appLog('selftest: changelog v$kAppVersion '
        '(${entry.items.length} 项) ✓');
  });

  await step('v02.wallpaperFile', () async {
    // 优先用真实封面图（磁盘已缓存的 JPEG，最贴近用户实际壁纸）；
    // 拿不到再回落 1×1 PNG（1px 图在个别引擎解码器上有边界情况）。
    var bytes = base64Decode(_tinyPngBase64);
    final coverUrl = player.currentTrack?.cover ?? '';
    if (coverUrl.isNotEmpty) {
      final cover = await resolveCoverFile(coverUrl);
      if (cover != null && cover.existsSync() && cover.lengthSync() > 1000) {
        bytes = await cover.readAsBytes();
        appLog('selftest: 壁纸夹具用真实封面 '
            '${cover.lengthSync()}B');
      }
    }
    final file = await wallpaperFile();
    await file.writeAsBytes(bytes, flush: true);
    if (!file.existsSync() || file.lengthSync() < 60) throw '壁纸写入失败';
    appLog('selftest: 相册壁纸落盘 ${file.path} '
        '(${file.lengthSync()}B) ✓');
  });

  // ---- 活体 UI（真实渲染 + FlutterError 计数）----

  await step('v02.uiPlayerMount', () async {
    final nav = navigatorKey.currentState;
    if (nav == null) throw 'navigator 未就绪';
    if (player.currentTrack == null) throw '无当前曲目（前置播放步骤未完成）';
    var errors = 0;
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      errors++;
      original?.call(details);
    };
    try {
      // 挂载播放 Tab（首页壳 IndexedStack 懒挂载）
      homeTabIndex.value = kPlayerTabIndex;
      await Future<void>.delayed(const Duration(milliseconds: 900));
      // 逐组实时切换个性化组合：播放页 ListenableBuilder 即时重建，
      // 覆盖 5 款进度条 × 壁纸四形态 × 主题色两种模式
      final combos = <(ProgressBarStyle, String, bool)>[
        (ProgressBarStyle.classic, 'auto', true),
        (ProgressBarStyle.streamer, 'gradient:sakura', false),
        (ProgressBarStyle.glow, 'custom', true),
        (ProgressBarStyle.aurora, 'gradient:midnight', false),
        (ProgressBarStyle.wave, 'photo', true),
        (ProgressBarStyle.wave, 'auto', true),
      ];
      for (final (bar, wallpaper, follow) in combos) {
        appearance
          ..setProgressBar(bar)
          ..setWallpaper(wallpaper)
          ..setAccent(followCover: follow);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (errors > 0) {
          throw '${bar.storage}/$wallpaper 组合触发 '
              '$errors 个渲染错误';
        }
      }
      // 快捷按钮重排实时生效（横向 ReorderableListView 重建）
      appearance
          .reorderPlayerActions(appearance.playerActions.length - 1, 0);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (errors > 0) throw '快捷按钮重排触发 $errors 个渲染错误';
    } finally {
      FlutterError.onError = original;
    }
    appLog('selftest: 播放页 6 组个性化组合 + 按钮重排实时渲染 ✓');
  });

  await step('v02.uiPages', () async {
    final nav = navigatorKey.currentState;
    if (nav == null) throw 'navigator 未就绪';
    var errors = 0;
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      errors++;
      original?.call(details);
    };
    try {
      nav.push(MaterialPageRoute<void>(
        builder: (_) => const AppearancePage(),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (errors > 0) throw '外观页渲染 $errors 个错误';
      nav.pop();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      nav.push(MaterialPageRoute<void>(
        builder: (_) => const RankingPage(),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (errors > 0) throw '排行页渲染 $errors 个错误';
      nav.pop();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final sheetContext = nav.context;
      if (!sheetContext.mounted) throw 'navigator context 未挂载';
      unawaited(showLyricsStyleSheet(sheetContext));
      await Future<void>.delayed(const Duration(milliseconds: 650));
      if (errors > 0) throw '歌词样式底单渲染 $errors 个错误';
      nav.pop();
      await Future<void>.delayed(const Duration(milliseconds: 350));
    } finally {
      FlutterError.onError = original;
    }
    appLog('selftest: 外观页 / 排行页 / 歌词样式底单渲染 ✓');
  });

  await step('v02.restoreDefaults', () async {
    appearance
      ..setAccent(followCover: true)
      ..updateLyrics(
        fontSize: 17,
        lineSpacing: 1.0,
        customColors: false,
        glow: false,
        tilt: false,
      )
      ..setProgressBar(ProgressBarStyle.classic)
      ..setWallpaper('auto')
      ..resetPlayerActions();
    await PlayStats.clear();
    try {
      (await wallpaperFile()).deleteSync();
    } catch (_) {
      // 无文件则忽略
    }
    homeTabIndex.value = 0;
    appLog('selftest: 外观与统计数据已恢复默认 ✓');
  });
}
