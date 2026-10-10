/// 喜欢列表：App 全局内容（本机持有，跨音源共享）。
///
/// * 存储：完整曲目（含平台曲目 kw_/wy_），SharedPreferences 持久化——
///   切换音源不影响；未登录也可用（本地喜欢）；
/// * 服务器合并：登录后与汽水账号喜欢列表取并集（只补不删，避免分页
///   不全造成误删）；App 对汽水账号只读不写；
/// * 旧版只存 id（likedTrackIds）：迁移为 legacy 标记，等服务器刷新
///   补全曲目信息。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'models.dart';

class LikedStore extends ChangeNotifier {
  static const _prefsKey = 'likedTracks';
  static const _legacyKey = 'likedTrackIds';

  final List<Track> _tracks = [];

  /// 旧版纯 id 记录（无曲目信息）：维持红心标记，等服务器刷新补全。
  final Set<String> _legacyIds = {};
  bool _syncing = false;

  bool get syncing => _syncing;
  int get count => _tracks.length + _legacyIds.length;

  /// 喜欢的曲目（有完整信息的部分），新在前。
  List<Track> get tracks => List.unmodifiable(_tracks);

  bool isLiked(String? trackId) =>
      trackId != null &&
      trackId.isNotEmpty &&
      (_legacyIds.contains(trackId) ||
          _tracks.any((track) => track.id == trackId));

  Track? byId(String trackId) {
    for (final track in _tracks) {
      if (track.id == trackId) return track;
    }
    return null;
  }

  /// 启动时从本地缓存恢复（秒开，不依赖网络）。
  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        _tracks
          ..clear()
          ..addAll(
            list.whereType<Map<String, dynamic>>().map(Track.fromJson),
          );
      } catch (_) {
        // 损坏数据当空处理
      }
    }
    // 旧版迁移：只存过 id 的维持标记位（新格式键一旦写入即清理）
    final legacy = prefs.getStringList(_legacyKey);
    if (legacy != null && legacy.isNotEmpty) {
      final known = _tracks.map((track) => track.id).toSet();
      _legacyIds
        ..clear()
        ..addAll(legacy.where((id) => !known.contains(id)));
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_tracks.map((track) => track.toJson()).toList()),
    );
    if (_legacyIds.isEmpty) await prefs.remove(_legacyKey);
  }

  /// 喜欢/取消喜欢（本机全局；对汽水账号不回写，服务器侧以官方 App 为准）。
  /// 返回操作后的喜欢状态。
  bool toggle(Track track) {
    if (track.id.isEmpty) return false;
    final liked = isLiked(track.id);
    if (liked) {
      _tracks.removeWhere((item) => item.id == track.id);
      _legacyIds.remove(track.id);
    } else {
      _legacyIds.remove(track.id);
      _tracks.insert(0, track);
    }
    _persist();
    notifyListeners();
    return !liked;
  }

  /// 登录后与汽水账号对齐（并集：只补不删，避免分页不全造成误删）。
  Future<void> refreshFromServer() async {
    if (_syncing) return;
    _syncing = true;
    notifyListeners();
    try {
      final tracks = await Api.likedSongs();
      var changed = false;
      final known = _tracks.map((track) => track.id).toSet();
      for (final track in tracks) {
        if (track.id.isEmpty) continue;
        if (_legacyIds.remove(track.id)) changed = true;
        if (known.add(track.id)) {
          _tracks.add(track); // 服务器曲目排到本地新喜欢的后面
          changed = true;
        }
      }
      if (changed) await _persist();
      notifyListeners();
    } catch (_) {
      // 拉取失败保持本地缓存即可
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }
}
