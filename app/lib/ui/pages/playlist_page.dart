import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/cache_index.dart';
import '../../core/logging.dart';
import '../../core/models.dart';
import '../../main.dart';
import '../widgets/skeleton.dart';
import '../widgets/track_tile.dart';

/// 歌单 / 我喜欢的音乐（本机红心 / 抖音账号喜欢）/ 抖音收藏的音乐
/// 详情页（只读）。
///
/// 头部（封面/创建者/播放/收藏统计/描述）来自 `/luna/playlist/detail`
/// 回包附带的元数据；拉不到时回退入口传入的 [item]。
class PlaylistPage extends StatefulWidget {
  const PlaylistPage({
    super.key,
    required this.title,
    required this.playlistId,
    this.liked = false,
    this.accountLiked = false,
    this.douyinFavorites = false,
    this.item,
  });

  final String title;
  final String playlistId;

  /// 入口携带的歌单条目（封面/创建者兜底数据）。
  final PlaylistItem? item;
  final bool liked;

  /// 打开「抖音账号我喜欢的」：汽水（抖音）账号侧喜欢列表，纯服务器
  /// 数据。与 [liked]（本机红心）是两份独立数据，互不同步。
  final bool accountLiked;

  /// 打开「抖音收藏的音乐」系统歌单（type=4）。
  final bool douyinFavorites;

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

/// 歌单展示排序（本地视图，不回写服务端顺序）。
enum _SortMode {
  original('默认顺序'),
  title('按歌名'),
  artist('按歌手');

  const _SortMode(this.label);
  final String label;
}

class _PlaylistPageState extends State<PlaylistPage> {
  List<Track> _tracks = [];
  PlaylistMeta? _meta;
  bool _loading = true;
  String? _error;

  /// 展示排序（纯本地视图，不影响服务端歌单顺序）。
  _SortMode _sort = _SortMode.original;

  // ---- 批量离线缓存 ----
  /// 正在批量缓存（底部条切换为进度态）。
  bool _caching = false;
  bool _cacheCancel = false;
  int _cacheDone = 0;
  int _cacheTotal = 0;

  List<Track> get _viewTracks {
    switch (_sort) {
      case _SortMode.title:
        return [..._tracks]
          ..sort((a, b) =>
              a.title.compareTo(b.title));
      case _SortMode.artist:
        return [..._tracks]
          ..sort((a, b) =>
              a.artist.compareTo(b.artist));
      case _SortMode.original:
        return _tracks;
    }
  }

  @override
  void initState() {
    super.initState();
    // 我喜欢的音乐：本地存储变更（服务器合并/取消喜欢）实时反映
    if (widget.liked) likedStore.addListener(_onLikedChanged);
    _load();
  }

  @override
  void dispose() {
    if (widget.liked) likedStore.removeListener(_onLikedChanged);
    super.dispose();
  }

  void _onLikedChanged() {
    if (!mounted || !widget.liked) return;
    setState(() => _tracks = likedStore.tracks);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      if (widget.liked) {
        // 我喜欢的音乐 = App 全局本地存储（跨音源；登录时与汽水账号并集）。
        // 打开时静默触发一次服务器合并，本地列表先行上屏。
        if (settings.hasCookie) unawaited(likedStore.refreshFromServer());
        if (!mounted) return;
        setState(() {
          _tracks = likedStore.tracks;
          _error = null;
        });
      } else if (widget.accountLiked) {
        // 抖音账号我喜欢的 = 服务器侧喜欢列表，每次进入直接拉取。
        final tracks = await Api.likedSongs();
        if (!mounted) return;
        setState(() {
          _tracks = tracks;
          _error = null;
        });
      } else if (widget.douyinFavorites) {
        final tracks = await Api.douyinFavorites();
        if (!mounted) return;
        setState(() {
          _tracks = tracks;
          _error = null;
        });
      } else {
        final detail = await Api.playlistDetail(widget.playlistId);
        if (!mounted) return;
        setState(() {
          _tracks = detail.tracks;
          _meta = detail.meta;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String get _title =>
      _meta?.title.isNotEmpty == true ? _meta!.title : widget.title;
  String get _cover => _meta?.cover.isNotEmpty == true
      ? _meta!.cover
      : widget.item?.cover ?? '';
  String get _creator => _meta?.creator.isNotEmpty == true
      ? _meta!.creator
      : widget.item?.creator ?? '';

  /// 批量离线缓存：逐首 prepare（走当前音源链路：汽水账号/SodaM 签名/洛雪
  /// 免费源自动回落），已缓存的跳过；FFI 全局锁决定必须串行。
  /// 缓存索引由 prepareTrack 内部自动写入（设置 → 已缓存曲目可见）。
  Future<void> _cacheAll() async {
    if (_caching || _tracks.isEmpty) return;
    final Set<String> cachedIds;
    try {
      cachedIds = (await CacheIndex.list()).map((e) => e.id).toSet();
    } catch (error) {
      appLog('playlist: 读缓存索引失败: $error');
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('读取缓存索引失败，请重试')));
      }
      return;
    }
    final pending =
        _tracks.where((track) => !cachedIds.contains(track.id)).toList();
    if (!mounted) return;
    if (pending.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('歌单里的歌都已缓存过啦'),
          duration: Duration(seconds: 2),
        ));
      return;
    }
    setState(() {
      _caching = true;
      _cacheCancel = false;
      _cacheDone = 0;
      _cacheTotal = pending.length;
    });
    var ok = 0;
    var fail = 0;
    for (final track in pending) {
      if (_cacheCancel) break;
      try {
        await Api.prepareTrack(track);
        ok++;
      } catch (error) {
        fail++;
        appLog('playlist: 批量缓存失败「${track.title}」: $error');
      }
      if (!mounted) return;
      setState(() => _cacheDone++);
    }
    if (!mounted) return;
    setState(() => _caching = false);
    final cancelled = _cacheCancel;
    final message = [
      '缓存完成：成功 $ok 首',
      if (fail > 0) '失败 $fail 首（详见日志）',
      if (cancelled) '已中止',
    ].join('，');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        edgeOffset: 220,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 220,
              pinned: true,
              title: Text(_title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              flexibleSpace: FlexibleSpaceBar(
                background: _HeaderBackground(cover: _cover),
              ),
              actions: [
                if (_tracks.isNotEmpty && !_caching)
                  IconButton(
                    tooltip: '缓存全部（离线可播）',
                    icon: const Icon(Icons.download_outlined),
                    onPressed: _cacheAll,
                  ),
                if (_tracks.length > 1)
                  PopupMenuButton<_SortMode>(
                    tooltip: '排序',
                    initialValue: _sort,
                    onSelected: (mode) => setState(() => _sort = mode),
                    itemBuilder: (context) => [
                      for (final mode in _SortMode.values)
                        PopupMenuItem(
                          value: mode,
                          child: Text(mode.label),
                        ),
                    ],
                    icon: const Icon(Icons.sort),
                  ),
              ],
            ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: SkeletonBody(count: 8),
                ),
              )
            else if (_error != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _errorView(scheme),
              )
            else ...[
              SliverToBoxAdapter(child: _headerInfo(context)),
              if (_sort != _SortMode.original)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      '当前视图：${_sort.label}（仅本机展示顺序，不改服务端歌单）',
                      style:
                          TextStyle(fontSize: 11.5, color: scheme.outline),
                    ),
                  ),
                ),
              if (_tracks.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 60),
                    child: Center(child: Text('歌单是空的')),
                  ),
                )
              else
                SliverList.builder(
                  itemCount: _viewTracks.length,
                  itemBuilder: (context, index) => TrackTile(
                    track: _viewTracks[index],
                    queue: _viewTracks,
                    showIndex: true,
                    index: index,
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
            ],
          ],
        ),
      ),
      bottomNavigationBar: _caching
          ? SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value:
                        _cacheTotal > 0 ? _cacheDone / _cacheTotal : null,
                    minHeight: 3,
                  ),
                  ListTile(
                    dense: true,
                    tileColor: scheme.secondaryContainer,
                    leading: const SizedBox(
                      width: 18,
                      height: 18,
                      child:
                          CircularProgressIndicator(strokeWidth: 2),
                    ),
                    title: Text(
                        '正在离线缓存 $_cacheDone/$_cacheTotal 首 · 走当前音源链路'),
                    trailing: TextButton(
                      onPressed: () => _cacheCancel = true,
                      child: const Text('取消'),
                    ),
                  ),
                ],
              ),
            )
          : _tracks.isEmpty
              ? null
              : SafeArea(
                  child: ListTile(
                    tileColor: scheme.secondaryContainer,
                    leading: const Icon(Icons.play_circle),
                    title: const Text('播放全部'),
                    subtitle: Text('${_tracks.length} 首'),
                    onTap: () => player.playQueue(_viewTracks, 0),
                  ),
                ),
    );
  }

  Widget _errorView(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            FilledButton.tonal(
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerInfo(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = _meta;
    final desc = meta?.desc.trim() ?? '';
    final stats = <String>[
      '${_tracks.length} 首',
      if (meta != null && meta.playCount > 0) '播放 ${_countLabel(meta.playCount)}',
      if (meta != null && meta.collectedCount > 0)
        '收藏 ${_countLabel(meta.collectedCount)}',
      if (meta?.isPrivate == true) '隐私歌单',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _title,
            style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold),
          ),
          if (_creator.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('by $_creator',
                style: TextStyle(fontSize: 12, color: scheme.outline)),
          ],
          if (stats.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(stats.join(' · '),
                style: TextStyle(fontSize: 12, color: scheme.outline)),
          ],
          if (desc.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              desc,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  String _countLabel(int value) {
    if (value >= 100000000) return '${(value / 100000000).toStringAsFixed(1)}亿';
    if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
    return '$value';
  }
}

/// 头部背景：封面垫底 + 渐变到页面底色（与专辑页同风格）。
class _HeaderBackground extends StatelessWidget {
  const _HeaderBackground({required this.cover});

  final String cover;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (cover.trim().isNotEmpty)
          Image.network(
            cover,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(color: scheme.primaryContainer),
          )
        else
          Container(color: scheme.primaryContainer),
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.05),
                scheme.surface.withValues(alpha: 0.92),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
