import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/errors.dart';
import '../../core/models.dart';
import '../../main.dart';
import '../widgets/cover.dart';
import '../widgets/skeleton.dart';
import 'artist_page.dart';

/// 我关注的艺人（服务端收藏）：列表 + 分页 + 进艺人页。
///
/// 关注操作在艺人页里（乐观 UI）；本页只读。当前账号若被
/// /luna/me/collection/artist 风控（1000006），列表回空并如实提示。
class FollowedArtistsPage extends StatefulWidget {
  const FollowedArtistsPage({super.key});

  @override
  State<FollowedArtistsPage> createState() => _FollowedArtistsPageState();
}

class _FollowedArtistsPageState extends State<FollowedArtistsPage> {
  final List<ArtistItem> _artists = [];
  String _cursor = '';
  bool _hasMore = false;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!settings.hasCookie) {
      _error = '登录后可见关注的艺人';
      return;
    }
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading) return;
    if (refresh) {
      setState(() {
        _artists.clear();
        _cursor = '';
        _error = null;
      });
    }
    setState(() => _loading = true);
    try {
      final page = await Api.collectedArtists(cursor: _cursor);
      if (!mounted) return;
      setState(() {
        final seen = _artists.map((artist) => artist.id).toSet();
        _artists.addAll(
            page.artists.where((artist) => !seen.contains(artist.id)));
        _cursor = page.nextCursor;
        _hasMore = page.hasMore && page.artists.isNotEmpty;
      });
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我关注的艺人')),
      body: _error != null && _artists.isEmpty
          ? ListView(children: [
              const SizedBox(height: 120),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Center(child: Text(_error!)),
              ),
            ])
          : _loading && _artists.isEmpty
              ? const SkeletonBody(count: 8)
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount:
                      _artists.length + (_hasMore || _artists.isEmpty ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= _artists.length) {
                      if (_artists.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: Text('还没有关注的艺人')),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(
                          child: OutlinedButton(
                            onPressed: () => _load(),
                            child: const Text('加载更多'),
                          ),
                        ),
                      );
                    }
                    final artist = _artists[index];
                    return ListTile(
                      leading: ClipOval(
                        child: artist.avatar.isEmpty
                            ? Container(
                                width: 48,
                                height: 48,
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                child: const Icon(Icons.person),
                              )
                            : CoverImage(url: artist.avatar, size: 48),
                      ),
                      title: Text(artist.name),
                      subtitle: artist.trackCount > 0
                          ? Text('${artist.trackCount} 首歌曲')
                          : null,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ArtistPage(
                            artistId: artist.id,
                            name: artist.name,
                            avatar: artist.avatar,
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
