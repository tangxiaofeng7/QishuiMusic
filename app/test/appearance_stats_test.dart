import 'package:flutter_test/flutter_test.dart';
import 'package:qishui_player/core/appearance.dart';
import 'package:qishui_player/core/models.dart';
import 'package:qishui_player/core/play_stats.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track _track(String id) => Track(
      id: id,
      title: '曲$id',
      artist: '艺人',
      album: '专辑',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayStats 听歌排行', () {
    test('record 累计 total/week，top 按对应维度排序', () async {
      SharedPreferences.setMockInitialValues({});
      await PlayStats.record(_track('a'));
      await PlayStats.record(_track('a'));
      await PlayStats.record(_track('b'));
      final weekly = await PlayStats.top(weekly: true);
      expect(weekly.length, 2);
      expect(weekly.first.track.id, 'a');
      expect(weekly.first.week, 2);
      final total = await PlayStats.top();
      expect(total.first.total, greaterThanOrEqualTo(2));
    });

    test('跨滚动周后周计数清零、总计数保留', () async {
      SharedPreferences.setMockInitialValues({});
      await PlayStats.record(_track('a'));
      // 手动把 weekStart 挪到 8 天前，触发滚动清零
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('playStats')!;
      final stale = raw.replaceFirst(
        RegExp(r'"weekStart":\d+'),
        '"weekStart":${DateTime.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch}',
      );
      await prefs.setString('playStats', stale);
      final weekly = await PlayStats.top(weekly: true);
      expect(weekly, isEmpty);
      final total = await PlayStats.top();
      expect(total.first.track.id, 'a');
      expect(total.first.total, 1);
      expect(total.first.week, 0);
    });

    test('clear 后为空', () async {
      SharedPreferences.setMockInitialValues({});
      await PlayStats.record(_track('a'));
      await PlayStats.clear();
      expect(await PlayStats.top(), isEmpty);
    });
  });

  group('Appearance 备份导出/导入', () {
    test('toBackupMap → applyBackupMap 往返一致（photo 壁纸回落 auto）', () async {
      SharedPreferences.setMockInitialValues({});
      final source = await Appearance.load();
      source.updateLyrics(fontSize: 24, lineSpacing: 1.6, glow: true);
      source.setProgressBar(ProgressBarStyle.aurora);
      source.setWallpaper('gradient:sakura');
      source.setAccent(followCover: false, color: 0xFF3D7BE8);
      final map = source.toBackupMap();

      final target = await Appearance.load();
      target.applyBackupMap(Map<String, dynamic>.from(map));
      expect(target.lyricFontSize, 24);
      expect(target.lyricLineSpacing, 1.6);
      expect(target.lyricGlow, isTrue);
      expect(target.progressBar, ProgressBarStyle.aurora);
      expect(target.wallpaper, 'gradient:sakura');
      expect(target.accentFollowCover, isFalse);
      expect(target.accentColor.toARGB32(), 0xFF3D7BE8);

      // 相册壁纸不随 JSON 搬：导出即回落 auto
      source.setWallpaper('photo');
      expect(source.toBackupMap()['wallpaper'], 'auto');
    });

    test('playerActions 只收编已知动作，未知 id 忽略', () async {
      SharedPreferences.setMockInitialValues({});
      final target = await Appearance.load();
      target.applyBackupMap({
        'playerActions': ['share', '不存在', 'queue'],
      });
      expect(target.playerActions, ['share', 'queue']);
    });

    test('reorderPlayerActions（onReorderItem 语义：newIndex 已校正）', () async {
      SharedPreferences.setMockInitialValues({});
      final app = await Appearance.load();
      // [queue, speed, sleep, translate, share, lyrics] 把 lyrics 挪到最前
      app.reorderPlayerActions(5, 0);
      expect(app.playerActions.first, 'lyrics');
      expect(app.playerActions.length, defaultPlayerActions.length);
    });
  });
}
