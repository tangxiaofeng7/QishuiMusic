/// 已缓存曲目索引：`<cacheDir>/tracks/index.json`。
///
/// 音频文件本体只有 `{id}-{quality}.m4a` 这类文件名（Rust 侧落盘），没有
/// 标题/歌手元数据；这里在每次 prepare 成功后补一条可读索引，供设置里
/// 「已缓存曲目」列表展示与点播。文件被删（清缓存/手动删）后条目在
/// 下次读取时自动失效。

library;

import 'dart:convert';
import 'dart:io';

import 'logging.dart';
import 'models.dart';
import 'store.dart' as store;

class CacheEntry {
  CacheEntry({
    required this.id,
    required this.title,
    required this.artist,
    this.album = '',
    this.cover = '',
    this.durationSeconds = 0,
    this.vip = false,
    this.platform = '',
    required this.quality,
    required this.source,
    required this.path,
    required this.bytes,
    required this.atMs,
  });

  factory CacheEntry.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    return CacheEntry(
      id: id,
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
      album: json['album']?.toString() ?? '',
      cover: json['cover']?.toString() ?? '',
      durationSeconds:
          int.tryParse(json['durationSeconds']?.toString() ?? '') ?? 0,
      vip: json['vip'] == true,
      // 旧索引条目没有 platform 字段：平台曲目 id 自带 `kw_`/`wy_` 前缀，
      // 从 id 推导兜底（丢失平台会让点播走错解析链、白白重新联网取流）。
      platform: (json['platform']?.toString() ?? '').isNotEmpty
          ? json['platform'].toString()
          : platformFromIdPrefix(id),
      quality: json['quality']?.toString() ?? '',
      source: json['source']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      bytes: int.tryParse(json['bytes']?.toString() ?? '') ?? 0,
      atMs: int.tryParse(json['atMs']?.toString() ?? '') ?? 0,
    );
  }

  final String id;
  final String title;
  final String artist;
  final String album;
  final String cover;
  final int durationSeconds;
  final bool vip;

  /// 曲目来源平台（'' = 汽水；'kw'/'wy'/… = 平台曲目，见 [Track.platform]）。
  final String platform;
  final String quality;
  final String source;
  final String path;
  final int bytes;
  final int atMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'cover': cover,
        'durationSeconds': durationSeconds,
        'vip': vip,
        'platform': platform,
        'quality': quality,
        'source': source,
        'path': path,
        'bytes': bytes,
        'atMs': atMs,
      };

  /// 还原为可播放曲目：带上 platform（走对解析链）与已验证的本地整曲
  /// 路径（播放链路直接放本地文件，点播零等待）。
  Track toTrack() => Track(
        id: id,
        title: title,
        artist: artist,
        album: album,
        cover: cover,
        durationSeconds: durationSeconds,
        vip: vip,
        platform: platform,
        cachedPath: path,
        cachedQuality: quality,
      );

  String get sizeLabel {
    if (bytes <= 0) return '';
    if (bytes < 1024 * 1024) return '${bytes ~/ 1024} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String get durationLabel {
    if (durationSeconds <= 0) return '--:--';
    final minutes = durationSeconds ~/ 60;
    final seconds = durationSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class CacheIndex {
  CacheIndex._();

  /// 串行化读写（播放加载与预取并发时避免读改写丢失）。
  static Future<void> _lock = Future.value();

  static Future<T> _sync<T>(Future<T> Function() action) {
    final run = _lock.then((_) => action());
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  static Future<File> _indexFile() async {
    final dir = Directory('${await store.Settings.resolveCacheDir()}/tracks');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}/index.json');
  }

  /// 读索引并剔除文件已不存在的条目（顺带把过期项写回）。
  static Future<List<CacheEntry>> list() => _sync(() async {
        final file = await _indexFile();
        if (!file.existsSync()) return const [];
        List<dynamic> raw;
        try {
          raw = jsonDecode(file.readAsStringSync()) as List;
        } catch (error) {
          appLog('cache-index: 索引损坏，重建: $error');
          return const [];
        }
        final entries = raw
            .whereType<Map>()
            .map((item) =>
                CacheEntry.fromJson(Map<String, dynamic>.from(item)))
            .where((entry) => entry.id.isNotEmpty)
            .toList();
        final alive = entries
            .where((entry) =>
                entry.path.isNotEmpty && File(entry.path).existsSync())
        .toList();
        if (alive.length != entries.length) {
          await _write(file, alive);
        }
        return alive;
      });

  static Future<void> _write(File file, List<CacheEntry> entries) async {
    try {
      file.writeAsStringSync(
          jsonEncode(entries.map((entry) => entry.toJson()).toList()));
    } catch (error) {
      appLog('cache-index: 写入失败(忽略): $error');
    }
  }

  /// 记录/更新一条（同一曲目保留最新音质档的那条；ext 与汽水分开记）。
  static Future<void> record(Track track,
      {required String quality, required String path, required String source}) {
    return _sync(() async {
      final file = await _indexFile();
      List<dynamic> raw = const [];
      if (file.existsSync()) {
        try {
          raw = jsonDecode(file.readAsStringSync()) as List;
        } catch (_) {
          raw = const [];
        }
      }
      final bytes = File(path).existsSync() ? File(path).lengthSync() : 0;
      final entry = CacheEntry(
        id: track.id,
        title: track.title,
        artist: track.artist,
        album: track.album,
        cover: track.cover,
        durationSeconds: track.durationSeconds,
        vip: track.vip,
        platform: track.platform,
        quality: quality,
        source: source,
        path: path,
        bytes: bytes,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
      final entries = raw
          .whereType<Map>()
          .map((item) => CacheEntry.fromJson(Map<String, dynamic>.from(item)))
          .where((item) =>
              item.id.isNotEmpty &&
              // 同曲目同来源的旧档先剔除（换音质重下后旧条目作废）
              !(item.id == entry.id && item.source == entry.source))
          .toList();
      entries.add(entry);
      await _write(file, entries);
    });
  }

  /// 删一条：音频文件 + 同 id 的汽水质档 sidecar + 索引条目。
  static Future<void> removeEntry(CacheEntry entry) => _sync(() async {
        try {
          final file = File(entry.path);
          if (file.existsSync()) file.deleteSync();
          // 汽水侧同名曲目的质档 sidecar 只在删汽水缓存时清；外部缓存只清
          // 自己的 {id}-ext-* 文件（同一曲目可能两者都有）。
          final isSoda = entry.source != 'ext';
          for (final item in file.parent.listSync()) {
            final name = item.path.split('/').last;
            final mine = isSoda
                ? name.startsWith('${entry.id}-')
                : name.startsWith('${entry.id}-ext-');
            if (mine &&
                (name.endsWith('.quality') || name.contains('-part.'))) {
              item.deleteSync();
            }
          }
        } catch (error) {
          appLog('cache-index: 删除文件失败(忽略): $error');
        }
        final file = await _indexFile();
        if (!file.existsSync()) return;
        try {
          final raw = jsonDecode(file.readAsStringSync()) as List;
          final entries = raw
              .whereType<Map>()
              .map((item) =>
                  CacheEntry.fromJson(Map<String, dynamic>.from(item)))
              .where((item) =>
                  !(item.id == entry.id && item.source == entry.source))
              .toList();
          await _write(file, entries);
        } catch (_) {
          // 索引异常时留待 list() 自愈
        }
      });

  /// 清空索引（音频文件由 Rust clearCache 清）。
  static Future<void> clear() => _sync(() async {
        final file = await _indexFile();
        if (file.existsSync()) {
          try {
            file.deleteSync();
          } catch (_) {}
        }
      });
}
