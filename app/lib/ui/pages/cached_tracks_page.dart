import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/cache_index.dart';
import '../../core/models.dart';
import '../../core/store.dart';
import '../../main.dart';
import '../widgets/cover.dart';

/// 已缓存曲目：本地已下载的整曲列表，点按即播（整表作为队列），
/// 左滑删除单条，右上角一键清空。
class CachedTracksPage extends StatefulWidget {
  const CachedTracksPage({super.key});

  @override
  State<CachedTracksPage> createState() => _CachedTracksPageState();
}

class _CachedTracksPageState extends State<CachedTracksPage> {
  List<CacheEntry> _entries = [];
  List<Track> _queue = [];
  int _totalBytes = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await CacheIndex.list();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      // 点播队列一次建好（曲目带本地缓存路径，点按零等待直放本地文件）
      _queue = entries.map((entry) => entry.toTrack()).toList();
      _totalBytes = entries.fold(0, (sum, entry) => sum + entry.bytes);
      _loading = false;
    });
  }

  Future<void> _delete(CacheEntry entry) async {
    await CacheIndex.removeEntry(entry);
    await _load();
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空缓存？'),
        content: const Text('将删除全部已缓存曲目与封面，不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await Api.clearCache();
    // Rust 只清音频缓存（缓存目录下 tracks/），封面缓存一并清理
    try {
      final dir = Directory('${await Settings.resolveCacheDir()}/covers');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // 封面目录缺失/清理失败忽略
    }
    await _load();
  }

  String get _sizeLabel {
    if (_totalBytes < 1024 * 1024) return '${_totalBytes ~/ 1024} KB';
    return '${(_totalBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('已缓存曲目'),
        actions: [
          if (_entries.isNotEmpty)
            TextButton(
              onPressed: _clearAll,
              child: const Text('清空'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? ListView(children: [
                  const SizedBox(height: 120),
                  Icon(Icons.download_done, size: 64, color: scheme.outline),
                  const SizedBox(height: 12),
                  Center(
                    child: Text('还没有缓存曲目',
                        style: TextStyle(color: scheme.outline)),
                  ),
                  const SizedBox(height: 6),
                  Center(
                    child: Text('播放过的整曲会自动缓存到这里',
                        style:
                            TextStyle(fontSize: 12, color: scheme.outline)),
                  ),
                ])
              : ListView.builder(
                  itemCount: _entries.length,
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    return Dismissible(
                      key: ValueKey('${entry.id}-${entry.source}'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: scheme.errorContainer,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: Icon(Icons.delete_outline,
                            color: scheme.onErrorContainer),
                      ),
                      confirmDismiss: (_) async {
                        return await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('删除缓存？'),
                            content: Text(
                                '「${entry.title}」的缓存文件将被删除。'),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(context, false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('删除'),
                              ),
                            ],
                          ),
                        );
                      },
                      onDismissed: (_) => _delete(entry),
                      child: ListTile(
                        leading:
                            CoverImage(url: entry.cover, size: 48),
                        title: Text(entry.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            if (entry.artist.isNotEmpty) entry.artist,
                            if (entry.source == 'ext') '外部音源',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(entry.quality,
                                style: TextStyle(
                                    fontSize: 12, color: scheme.primary)),
                            Text(
                              '${entry.sizeLabel}  ·  ${entry.durationLabel}',
                              style: TextStyle(
                                  fontSize: 11, color: scheme.outline),
                            ),
                          ],
                        ),
                        onTap: () =>
                            player.playQueue(_queue, index),
                      ),
                    );
                  },
                ),
      bottomNavigationBar: _entries.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(
                  '${_entries.length} 首 · 共 $_sizeLabel',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ),
            ),
    );
  }
}
