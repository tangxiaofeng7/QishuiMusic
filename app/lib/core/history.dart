/// 本地历史：最近播放（曲目）与搜索历史（关键词），SharedPreferences 持久化。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class PlayHistory {
  static const _prefsKey = 'playHistory';
  static const _max = 100;

  static Future<List<Track>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map<String, dynamic>>()
          .map(Track.fromJson)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// 记录一次播放：同曲去重置顶，最多保留 [_max] 条。
  static Future<void> record(Track track) async {
    if (track.id.isEmpty) return;
    final tracks = (await load()).toList();
    tracks.removeWhere((item) => item.id == track.id);
    tracks.insert(0, track);
    if (tracks.length > _max) tracks.removeRange(_max, tracks.length);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode(tracks.map((item) => item.toJson()).toList()));
  }

  /// 删除单条本机历史（最近播放左滑删除用）。
  static Future<void> remove(String trackId) async {
    if (trackId.isEmpty) return;
    final tracks = (await load()).toList()
      ..removeWhere((item) => item.id == trackId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode(tracks.map((item) => item.toJson()).toList()));
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}

class SearchHistory {
  static const _prefsKey = 'searchHistory';
  static const _max = 10;

  static Future<List<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_prefsKey) ?? const [];
  }

  static Future<void> record(String keyword) async {
    keyword = keyword.trim();
    if (keyword.isEmpty) return;
    final words = (await load()).toList();
    words.remove(keyword);
    words.insert(0, keyword);
    if (words.length > _max) words.removeRange(_max, words.length);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, words);
  }

  static Future<void> remove(String keyword) async {
    final words = (await load()).toList()..remove(keyword);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, words);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
