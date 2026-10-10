/// 「我的」页持久缓存：`<cacheDir>/mine.json`。
///
/// 账号信息落盘，进 App/切 Tab 时先渲染缓存（零等待），后台超过保鲜期
/// 才静默刷新；退出登录时整体清空。iOS 上 tmp 目录在磁盘吃紧时可能被
/// 系统回收——那正好退化为首次全量加载，不影响正确性。

library;

import 'dart:convert';
import 'dart:io';

import 'logging.dart';
import 'models.dart';
import 'store.dart' as store;

class MineSnapshot {
  const MineSnapshot({
    required this.account,
    required this.savedAtMs,
  });

  final AccountInfo? account;
  final int savedAtMs;

  /// 缓存保鲜期：超过后挂载页面会触发一次静默刷新。
  bool get stale =>
      DateTime.now().millisecondsSinceEpoch - savedAtMs >
      const Duration(minutes: 10).inMilliseconds;
}

class MineCache {
  MineCache._();

  static Future<File> _file() async {
    final dir = Directory(await store.Settings.resolveCacheDir());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}/mine.json');
  }

  static Future<MineSnapshot?> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return null;
      final value = jsonDecode(file.readAsStringSync());
      if (value is! Map) return null;
      final account = value['account'] is Map
          ? AccountInfo.fromJson(
              Map<String, dynamic>.from(value['account'] as Map))
          : null;
      return MineSnapshot(
        account: account,
        savedAtMs: int.tryParse(value['savedAtMs']?.toString() ?? '') ?? 0,
      );
    } catch (error) {
      appLog('mine-cache: 读取失败(视为无缓存): $error');
      return null;
    }
  }

  static Future<void> save(AccountInfo? account) async {
    try {
      final file = await _file();
      file.writeAsStringSync(jsonEncode({
        'account': account?.toJson(),
        'savedAtMs': DateTime.now().millisecondsSinceEpoch,
      }));
    } catch (error) {
      appLog('mine-cache: 写入失败(忽略): $error');
    }
  }

  /// 退出登录时清空。
  static Future<void> clear() async {
    try {
      final file = await _file();
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}
