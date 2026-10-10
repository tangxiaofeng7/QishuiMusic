import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/errors.dart';
import '../../core/models.dart';
import '../../main.dart';
import '../widgets/cover.dart';
import '../widgets/skeleton.dart';

/// 我的音乐墙（官方个人主页对位）：口味标签 + 最爱曲目封面墙。
///
/// 数据来自 PC 形态 `GET /luna/me/music_wall`；点封面把整面墙作为
/// 队列从该曲开始播放。
class MusicWallPage extends StatefulWidget {
  const MusicWallPage({super.key});

  @override
  State<MusicWallPage> createState() => _MusicWallPageState();
}

class _MusicWallPageState extends State<MusicWallPage> {
  final List<Track> _tracks = [];
  final List<MusicWallTag> _tags = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!settings.hasCookie) {
      _error = '登录后可见你的音乐墙';
      return;
    }
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final wall = await Api.musicWall();
      if (!mounted) return;
      setState(() {
        _tracks
          ..clear()
          ..addAll(wall.tracks);
        _tags
          ..clear()
          ..addAll(wall.tags);
      });
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的音乐墙'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _error != null && _tracks.isEmpty
          ? _emptyView(scheme, _error!)
          : _loading && _tracks.isEmpty
              ? const SkeletonBody(count: 6)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      if (_tags.isNotEmpty) _tagHeader(scheme),
                      if (_tracks.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _emptyView(scheme, '墙还是空的：多听几首歌就有了'),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 120),
                          sliver: SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                              childAspectRatio: 0.72,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) => _wallTile(
                                scheme,
                                _tracks[index],
                                index,
                              ),
                              childCount: _tracks.length,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }

  Widget _emptyView(ColorScheme scheme, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );

  /// 口味标签横滑条（服务端配色，点不到就纯展示）。
  Widget _tagHeader(ColorScheme scheme) => SliverToBoxAdapter(
        child: SizedBox(
          height: 56,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            itemCount: _tags.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final tag = _tags[index];
              final color = tag.color;
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: color ?? scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Text(
                    tag.tag,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: color == null
                          ? scheme.onSecondaryContainer
                          : _textColorOn(color),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );

  /// 深浅判断粗糙但够用：按亮度选黑/白文字。
  Color _textColorOn(Color background) {
    final luminance = 0.299 * (background.r * 255).round() +
        0.587 * (background.g * 255).round() +
        0.114 * (background.b * 255).round();
    return luminance > 150 ? const Color(0xFF1C1B1F) : Colors.white;
  }

  Widget _wallTile(ColorScheme scheme, Track track, int index) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => player.playQueue(_tracks, index),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: track.cover.isEmpty
                      ? Container(
                          color: scheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.music_note,
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      : CoverImage(url: track.cover),
                ),
                if (index < 3)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'TOP ${index + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          Text(
            track.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
