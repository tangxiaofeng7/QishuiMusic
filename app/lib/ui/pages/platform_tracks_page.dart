import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/errors.dart';
import '../../core/lx_catalog.dart';
import '../../core/models.dart';
import '../../main.dart';
import '../widgets/skeleton.dart';
import '../widgets/track_tile.dart';

/// 平台曲目列表页（LX 模式曲库）：按榜单 id 或关键词分页拉曲目。
///
/// 发现页榜单卡、首页榜单卡的「查看全部」都落到这里——kg/wy/tx 传
/// 真榜单 id（免签榜单接口），kw 传关键词（搜索流兜底），二者共用
/// 同一曲曲目列表形态。
class PlatformTracksPage extends StatefulWidget {
  const PlatformTracksPage({
    super.key,
    required this.platform,
    this.keyword = '',
    this.chartId = '',
    this.title = '',
  });

  final String platform;

  /// 关键词模式（平台搜索流）。
  final String keyword;

  /// 榜单模式（免签真榜单；酷我时即关键词）。
  final String chartId;

  final String title;

  @override
  State<PlatformTracksPage> createState() => _PlatformTracksPageState();
}

class _PlatformTracksPageState extends State<PlatformTracksPage> {
  final ScrollController _scroll = ScrollController();
  final List<Track> _tracks = [];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600 && !_loading && _hasMore) {
        _loadMore();
      }
    });
    _loadMore();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _tracks.clear();
      _page = 0;
      _hasMore = true;
      _error = null;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final result = widget.chartId.isNotEmpty
          ? await Api.chartTracks(widget.platform, widget.chartId,
              page: _page + 1)
          : await Api.platformTracks(widget.platform, widget.keyword,
              page: _page + 1);
      if (!mounted) return;
      // 跨页去重：平台接口翻页偶有重复条目
      final seen = _tracks.map((track) => track.id).toSet();
      setState(() {
        if (_page == 0) _tracks.clear();
        _tracks.addAll(result.tracks.where((t) => seen.add(t.id)));
        _page += 1;
        _hasMore = result.hasMore;
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = _tracks.isEmpty ? friendlyError(error) : null);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String get _defaultTitle {
    final name = lxPlatformName(widget.platform);
    final label = widget.chartId.isNotEmpty
        ? lxCatalogFor(widget.platform)
            .where((chart) => chart.id == widget.chartId)
            .firstOrNull
            ?.title
        : widget.keyword;
    return '$name · ${label ?? ''}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
            widget.title.isEmpty ? _defaultTitle : widget.title),
        actions: [
          IconButton(
            tooltip: '播放全部',
            icon: const Icon(Icons.play_circle),
            onPressed: _tracks.isEmpty
                ? null
                : () => player.playQueue(_tracks, 0),
          ),
        ],
      ),
      body: _error != null && _tracks.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!),
                  ),
                  FilledButton.tonal(
                    onPressed: _reload,
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          : _loading && _tracks.isEmpty
              ? const SkeletonBody(count: 9)
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.builder(
                    controller: _scroll,
                    itemCount: _tracks.length + (_hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _tracks.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        );
                      }
                      return TrackTile(
                        track: _tracks[index],
                        queue: _tracks,
                        showIndex: true,
                        index: index,
                      );
                    },
                  ),
                ),
    );
  }
}
