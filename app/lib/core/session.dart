/// 播放会话持久化：队列 / 当前曲目 / 播放模式 / 进度，
/// 重启 App 后恢复到「上次听到的那首」（不自动播放，避免开 App 即耗流量）。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class PlaySession {
  static const _prefsKey = 'playSession';

  /// 队列保存上限：过长时以当前曲目为中心开窗，避免 prefs 单键过大。
  static const _maxTracks = 500;

  const PlaySession({
    required this.tracks,
    required this.index,
    required this.playMode,
    required this.positionMs,
  });

  final List<Track> tracks;
  final int index;

  /// PlayMode.name（字符串解耦，避免与 player.dart 循环依赖）。
  final String playMode;
  final int positionMs;

  factory PlaySession.fromJson(Map<String, dynamic> json) {
    final tracks = parseTracks(json['tracks']);
    final index = (json['index'] as num?)?.toInt() ?? 0;
    final mode = json['playMode']?.toString() ?? 'sequence';
    return PlaySession(
      tracks: tracks,
      index: tracks.isEmpty ? 0 : index.clamp(0, tracks.length - 1),
      playMode: ['sequence', 'repeatOne', 'shuffle'].contains(mode)
          ? mode
          : 'sequence',
      positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<PlaySession?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final session =
          PlaySession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      return session.tracks.isEmpty ? null : session;
    } catch (_) {
      return null;
    }
  }

  /// 保存当前播放现场；队列超限时以 [index] 为中心开窗（index 相应平移）。
  static Future<void> save({
    required List<Track> tracks,
    required int index,
    required String playMode,
    required int positionMs,
  }) async {
    if (tracks.isEmpty) return;
    var start = 0;
    var list = tracks;
    if (tracks.length > _maxTracks) {
      start = (index - _maxTracks ~/ 2).clamp(0, tracks.length - _maxTracks);
      list = tracks.sublist(start, start + _maxTracks);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        'tracks': list.map((track) => track.toJson()).toList(),
        'index': index - start,
        'playMode': playMode,
        'positionMs': positionMs,
      }),
    );
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
