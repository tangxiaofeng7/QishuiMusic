/// 听歌排行（本机播放次数统计）：最近一周 / 全部两个维度。
///
/// 计数时机与最近播放一致：曲目加载成功即 +1（player._load 成功路径）。
/// 「最近一周」为滚动 7 天：存 weekStart 时间戳，跨周时把所有周计数
/// 清零重开——不做日历周，任意一天看都是「过去 7 天」。
/// SharedPreferences 单键 JSON 持久化，最多保留 500 首防止无限膨胀。

library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class PlayStatsEntry {
  const PlayStatsEntry({
    required this.track,
    required this.total,
    required this.week,
  });

  final Track track;
  final int total;
  final int week;
}

class PlayStats {
  static const _prefsKey = 'playStats';
  static const _maxEntries = 500;

  /// 滚动周长度。
  static const _weekSpan = Duration(days: 7);

  static int? _weekStartMs;

  static List<PlayStatsEntry> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _weekStartMs = (map['weekStart'] as num?)?.toInt();
      final items = map['items'] as List? ?? const [];
      return items
          .whereType<Map<String, dynamic>>()
          .map((item) => PlayStatsEntry(
                track: Track.fromJson(item),
                total: (item['total'] as num?)?.toInt() ?? 0,
                week: (item['week'] as num?)?.toInt() ?? 0,
              ))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _encode(List<PlayStatsEntry> entries) async {
    // 只留 total > 0 的条目，按总次数裁剪
    entries = entries.where((entry) => entry.total > 0).toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    if (entries.length > _maxEntries) {
      entries = entries.sublist(0, _maxEntries);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        'weekStart': _weekStartMs,
        'items': entries
            .map((entry) => {
                  ...entry.track.toJson(),
                  'total': entry.total,
                  'week': entry.week,
                })
            .toList(),
      }),
    );
  }

  /// 跨周滚动清零：距 weekStart 超过 7 天则周计数重开。
  static List<PlayStatsEntry> _rollover(List<PlayStatsEntry> entries) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final weekStart = _weekStartMs;
    if (weekStart == null) {
      _weekStartMs = now;
      return entries;
    }
    if (now - weekStart < _weekSpan.inMilliseconds) return entries;
    _weekStartMs = now;
    return entries
        .map((entry) =>
            entry.week == 0 ? entry : PlayStatsEntry(
              track: entry.track,
              total: entry.total,
              week: 0,
            ))
        .toList();
  }

  /// 记一次播放（曲目加载成功时调用；失败静默）。
  static Future<void> record(Track track) async {
    if (track.id.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      var entries = _rollover(_decode(prefs.getString(_prefsKey)).toList());
      final index = entries.indexWhere((entry) => entry.track.id == track.id);
      if (index >= 0) {
        final old = entries[index];
        entries[index] = PlayStatsEntry(
          track: track,
          total: old.total + 1,
          week: old.week + 1,
        );
      } else {
        entries.add(PlayStatsEntry(track: track, total: 1, week: 1));
      }
      await _encode(entries);
    } catch (_) {
      // 统计不阻断播放
    }
  }

  /// 榜单：[weekly] true = 最近一周，false = 全部。
  static Future<List<PlayStatsEntry>> top({bool weekly = false, int limit = 100}) async {
    final prefs = await SharedPreferences.getInstance();
    var entries = _rollover(_decode(prefs.getString(_prefsKey)).toList());
    // 顺手把跨周结果落盘（下次读不用重复滚动）
    entries.sort((a, b) => weekly
        ? b.week.compareTo(a.week)
        : b.total.compareTo(a.total));
    return entries
        .where((entry) => (weekly ? entry.week : entry.total) > 0)
        .take(limit)
        .toList(growable: false);
  }

  static Future<void> clear() async {
    _weekStartMs = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
