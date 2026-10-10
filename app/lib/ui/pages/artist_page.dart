import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/logging.dart';
import '../../core/models.dart';
import '../widgets/cover.dart';
import '../widgets/skeleton.dart';
import '../widgets/track_tile.dart';
import 'album_page.dart';

/// 艺人页：头像/统计 + 热门歌曲（分页）+ 专辑（横向卡片）。
///
/// 数据走 PC 形态端点（/luna/pc/artists/*）；被签名门禁拒时给出可读
/// 提示与重试，不影响 App 其它页面。
class ArtistPage extends StatefulWidget {
  const ArtistPage({
    super.key,
    required this.artistId,
    this.name = '',
    this.avatar = '',
  });

  final String artistId;
  final String name;
  final String avatar;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  ArtistDetail? _detail;
  String? _error;
  bool _loading = true;

  final List<Track> _tracks = [];
  bool _tracksHasMore = false;
  String _tracksCursor = '';
  bool _loadingMore = false;

  List<AlbumItem> _albums = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // 专辑列表与详情互不依赖：并发拉取（原先「详情→单曲→专辑」三段
    // 串行，页面要等满三个请求往返）。
    final albumsFuture = Api.artistAlbums(widget.artistId).then((page) {
      _albums = page.albums;
    }).catchError((Object error) {
      appLog('artist: 专辑列表拉取失败（忽略）: $error');
    });
    try {
      final detail = await Api.artistDetail(widget.artistId);
      _detail = detail;
      _tracks
        ..clear()
        ..addAll(detail.hotTracks);
      // 热门歌曲不满一页时直接尝试拉全量单曲列表补齐。
      if (_tracks.length < 20) {
        try {
          final page = await Api.artistTracks(widget.artistId);
          if (page.tracks.isNotEmpty) {
            final seen = _tracks.map((track) => track.id).toSet();
            for (final track in page.tracks) {
              if (seen.add(track.id)) _tracks.add(track);
            }
            _tracksHasMore = page.hasMore;
            _tracksCursor = page.nextCursor;
          }
        } catch (error) {
          appLog('artist: 单曲列表拉取失败（忽略）: $error');
        }
      }
      await albumsFuture;
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_tracksHasMore || _tracksCursor.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final page = await Api.artistTracks(widget.artistId,
          cursor: _tracksCursor);
      final seen = _tracks.map((track) => track.id).toSet();
      for (final track in page.tracks) {
        if (seen.add(track.id)) _tracks.add(track);
      }
      _tracksHasMore = page.hasMore;
      _tracksCursor = page.nextCursor;
    } catch (error) {
      appLog('artist: 加载更多单曲失败: $error');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _detail?.name.isNotEmpty == true ? _detail!.name : widget.name;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 240,
            pinned: true,
            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            flexibleSpace: FlexibleSpaceBar(
              background: _HeaderBackground(avatar: _detail?.avatar ?? widget.avatar),
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
              child: _ErrorView(message: _error!, onRetry: _load),
            )
          else ...[
            SliverToBoxAdapter(child: _infoCard(context, name)),
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('热门歌曲',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
            SliverList.builder(
              itemCount: _tracks.length + (_tracksHasMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _tracks.length) {
                  _loadMore();
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                        child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2))),
                  );
                }
                return TrackTile(
                    track: _tracks[index], queue: _tracks, showIndex: true, index: index);
              },
            ),
            if (_tracks.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('暂无单曲')),
                ),
              ),
            if (_albums.isNotEmpty) ...[
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text('专辑',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ),
              ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 188,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemCount: _albums.length,
                    itemBuilder: (context, index) => _albumCard(context, _albums[index]),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ],
        ],
      ),
    );
  }

  Widget _infoCard(BuildContext context, String name) {
    final detail = _detail;
    final follower = detail?.followerCount ?? 0;
    final trackCount = detail?.trackCount ?? _tracks.length;
    String countLabel(int value) =>
        value >= 100000000
            ? '${(value / 100000000).toStringAsFixed(1)}亿'
            : value >= 10000
                ? '${(value / 10000).toStringAsFixed(1)}万'
                : '$value';
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        children: [
          Row(
            children: [
              Flexible(
                child: Text(name,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 10),
              if (follower > 0)
                Text('${countLabel(follower)} 人收藏',
                    style: TextStyle(fontSize: 12, color: scheme.outline)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text('单曲 $trackCount',
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
              const SizedBox(width: 16),
              Text('专辑 ${_albums.length}',
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _albumCard(BuildContext context, AlbumItem album) {
    return SizedBox(
      width: 124,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => AlbumPage(
            albumId: album.id,
            title: album.title,
            artist: album.artist,
            cover: album.cover,
          ),
        )),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CoverImage(url: album.cover, size: 124),
            ),
            const SizedBox(height: 6),
            Text(album.title,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            Text('${album.trackCount} 首',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}

/// 头部背景：头像模糊垫底 + 渐变遮罩（无头像时主题色渐变）。
class _HeaderBackground extends StatelessWidget {
  const _HeaderBackground({required this.avatar});

  final String avatar;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (avatar.trim().isNotEmpty)
          Image.network(
            avatar,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              color: scheme.primaryContainer,
            ),
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
                scheme.surface.withValues(alpha: 0.9),
              ],
            ),
          ),
        ),
        Center(
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: scheme.surface, width: 2.5),
            ),
            child: CircleAvatar(
              radius: 52,
              backgroundImage: avatar.trim().isNotEmpty
                  ? NetworkImage(avatar)
                  : null,
              backgroundColor: scheme.secondaryContainer,
              child: avatar.trim().isEmpty
                  ? Icon(Icons.person, size: 52, color: scheme.outline)
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
