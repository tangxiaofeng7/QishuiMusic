import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../main.dart';
import '../widgets/cover.dart';
import '../widgets/skeleton.dart';
import '../widgets/track_tile.dart';

/// 专辑详情页：头部（封面 / 标题 / 艺人）+ 曲目列表。
/// 元信息由搜索结果带入，曲目实时拉取（公开分享页，无需登录）。
class AlbumPage extends StatefulWidget {
  const AlbumPage({
    super.key,
    required this.albumId,
    required this.title,
    this.artist = '',
    this.cover = '',
  });

  final String albumId;
  final String title;
  final String artist;
  final String cover;

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  List<Track> _tracks = [];
  AlbumMeta? _meta;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // 曲目 + 元信息（发行时间/简介）一次拿全；分享页解析失败时 meta 为空
      final detail = await Api.albumDetail(widget.albumId);
      if (!mounted) return;
      setState(() {
        _tracks = detail.tracks;
        _meta = detail.meta;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              pinned: true,
              expandedHeight: 168,
              flexibleSpace: FlexibleSpaceBar(
                background: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Theme.of(context)
                            .colorScheme
                            .primaryContainer
                            .withValues(alpha: 0.6),
                        Theme.of(context).scaffoldBackgroundColor,
                      ],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 64, 20, 8),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: CoverImage(url: widget.cover, size: 96),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _meta?.title.isNotEmpty == true
                                    ? _meta!.title
                                    : widget.title,
                                style: Theme.of(context).textTheme.titleLarge,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if ((_meta?.artist ?? widget.artist).isNotEmpty)
                                Text(
                                  _meta?.artist ?? widget.artist,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              const SizedBox(height: 6),
                              Text(
                                [
                                  if (_meta?.releaseDateLabel != null)
                                    '发行于 ${_meta!.releaseDateLabel}',
                                  _error == null && !_loading
                                      ? '共 ${_tracks.length} 首'
                                      : '',
                                ]
                                    .where((part) => part.isNotEmpty)
                                    .join(' · '),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
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
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!),
                      ),
                      FilledButton.tonal(
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              if (_meta?.description.isNotEmpty == true)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Text(
                      _meta!.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              if (_tracks.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 60),
                    child: Center(child: Text('专辑里没有曲目')),
                  ),
                )
              else
                SliverList.builder(
                  itemCount: _tracks.length,
                  itemBuilder: (context, index) => TrackTile(
                    track: _tracks[index],
                    queue: _tracks,
                    showIndex: true,
                    index: index,
                  ),
                ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: _tracks.isEmpty
          ? null
          : SafeArea(
              child: ListTile(
                tileColor: Theme.of(context).colorScheme.secondaryContainer,
                leading: const Icon(Icons.play_circle),
                title: const Text('播放全部'),
                subtitle: Text('${_tracks.length} 首'),
                onTap: () => player.playQueue(_tracks, 0),
              ),
            ),
    );
  }
}
