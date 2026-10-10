/// 页面级 SWR（stale-while-revalidate）磁盘缓存：`<cacheDir>/pages/<key>.json`。
///
/// 目标对齐官方客户端的「秒开」体验：进页面先渲染上次内容（零等待），
/// 后台拉新成功后覆盖；网络失败时旧内容继续可用。与 [MineCache] 同思路，
/// 推广到首页/发现页/搜索热词/歌词等高频页面。退出登录时整体清空。

library;

import 'dart:convert';
import 'dart:io';

import 'logging.dart';
import 'store.dart' as store;

class PageCache {
  PageCache._();

  static Future<Directory> _dir() async {
    final base = Directory(await store.Settings.resolveCacheDir());
    final dir = Directory('${base.path}/pages');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 读缓存；不存在/损坏返回 null（损坏静默删除，视为未缓存）。
  static Future<Map<String, dynamic>?> readJson(String key) async {
    try {
      final file = File('${(await _dir()).path}/$key.json');
      if (!file.existsSync()) return null;
      final value = jsonDecode(file.readAsStringSync());
      if (value is! Map<String, dynamic>) return null;
      return value;
    } catch (error) {
      appLog('page-cache: 读取 $key 失败(视为无缓存): $error');
      return null;
    }
  }

  /// 写缓存（失败静默：缓存不可用不影响主流程）。
  static Future<void> writeJson(String key, Map<String, dynamic> value) async {
    try {
      final file = File('${(await _dir()).path}/$key.json');
      file.writeAsStringSync(jsonEncode(value));
    } catch (error) {
      appLog('page-cache: 写入 $key 失败(忽略): $error');
    }
  }

  /// 退出登录时整体清空（与 MineCache.clear 同步调用）。
  static Future<void> clearAll() async {
    try {
      final dir = await _dir();
      if (dir.existsSync()) {
        for (final entry in dir.listSync()) {
          if (entry is File) entry.deleteSync();
        }
      }
    } catch (error) {
      appLog('page-cache: 清空失败(忽略): $error');
    }
  }

  static Future<List<T>> readList<T>(String key, String field,
      T Function(Map<String, dynamic>) fromJson) async {
    final value = await readJson(key);
    final list = value?[field];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((item) => fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  static Future<void> writeList(String key, String field, List<Object?> items) =>
      writeJson(key, {field: items});
}
