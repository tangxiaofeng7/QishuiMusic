import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/errors.dart';
import '../../core/logging.dart';
import '../../core/mine_cache.dart';
import '../../core/models.dart';
import '../../core/page_cache.dart';
import '../../core/store.dart';
import '../../main.dart';
import '../widgets/cover.dart';
import 'album_page.dart';
import 'login_page.dart';
import 'playlist_page.dart';
import 'ranking_page.dart';
import 'recent_page.dart';

/// 我的：账号信息 / 全局内容（最近播放、听歌排行）/ 收藏内容。
///
/// * 最近播放与听歌排行是 **App 全局内容**：与播放音源无关
///   （切到其他音源后平台曲目同样进列表），未登录也可见；
/// * 我喜欢的音乐是 **App 全局内容**：本机红心列表（播放页红心），
///   跨音源共享、未登录可用，入口在「我的」（所有音源可见）；
///   首页汽水形态另有「抖音账号喜欢」入口，那是服务器侧数据，
///   与本机红心互不同步；
/// * 汽水账号区（账号信息/收藏）只在登录后出现；
/// * 音乐墙/抖音收藏/关注艺人是汽水账号内容，入口在首页（仅汽水
///   音源时显示）。
///
/// 缓存策略（用户未退出期间用缓存，不每次重拉）：
/// * 进页先渲染持久缓存（`mine.json`，秒开）；
/// * 缓存超过 10 分钟或不存在才静默刷新一次（有数据时无加载态、不打断）；
/// * 下拉刷新总是强制重拉；退出登录清空缓存。
class MinePage extends StatefulWidget {
  const MinePage({super.key, required this.onSettingsChanged});

  final VoidCallback onSettingsChanged;

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  AccountInfo? _account;
  List<PlaylistItem> _collected = [];
  List<AlbumItem> _collectedAlbums = [];
  bool _loading = false;
  String? _error;
  bool _hasCacheData = false;
  DateTime _lastFetched = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _restoreFromCache();
  }

  /// 先渲染持久缓存，再按需静默刷新。
  Future<void> _restoreFromCache() async {
    final snapshot = await MineCache.load();
    if (!mounted) return;
    if (snapshot != null) {
      setState(() {
        _account = snapshot.account;
        _hasCacheData = snapshot.account != null;
        _lastFetched =
            DateTime.fromMillisecondsSinceEpoch(snapshot.savedAtMs);
      });
    }
    if (settings.hasCookie && (snapshot == null || snapshot.stale)) {
      unawaited(_load());
    }
  }

  Future<void> _load({bool force = false}) async {
    if (!settings.hasCookie) return;
    // 未强制且数据仍新鲜：直接用缓存，不打网络。
    if (!force &&
        _hasCacheData &&
        DateTime.now().difference(_lastFetched) <
            const Duration(minutes: 10)) {
      return;
    }
    setState(() => _loading = _account == null);
    // 账号与收藏互不依赖：并发拉取（原先账号→收藏歌单→收藏专辑三段
    // 串行，页面下半屏要多等两个完整请求往返）。
    final collected = _loadCollected();
    try {
      final account = await Api.account();
      if (!mounted) return;
      setState(() {
        _account = account;
        _error = null;
        _hasCacheData = true;
        _lastFetched = DateTime.now();
      });
      await MineCache.save(account);
      await collected;
    } catch (error) {
      if (mounted) {
        setState(() => _error = _hasCacheData ? null : friendlyError(error));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 收藏的歌单（他人歌单）：静默加载，失败不打扰（服务可能不支持）。
  Future<void> _loadCollected() async {
    try {
      final collected = await Api.collectedPlaylists();
      if (mounted) setState(() => _collected = collected);
    } catch (error) {
      appLog('mine: 收藏的歌单拉取失败（忽略）: $error');
    }
    unawaited(_loadCollectedAlbums());
  }

  /// 收藏的专辑：静默加载，失败不打扰（同收藏歌单模式）。
  Future<void> _loadCollectedAlbums() async {
    try {
      final result = await Api.collectedAlbums();
      if (mounted) setState(() => _collectedAlbums = result.albums);
    } catch (error) {
      appLog('mine: 收藏的专辑拉取失败（忽略）: $error');
    }
  }

  Future<void> _logout() async {
    settings.cookie = '';
    await settings.save();
    final cacheDir = await Settings.resolveCacheDir();
    await Api.configure(settings.toFfiConfig(cacheDir));
    await MineCache.clear();
    await PageCache.clearAll(); // 页面级 SWR 缓存同属账号内容，一并清空
    if (mounted) {
      setState(() {
        _account = null;
        _error = null;
        _hasCacheData = false;
      });
      widget.onSettingsChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: ListView(
          children: [
            if (!settings.hasCookie)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.account_circle,
                        size: 72, color: scheme.outline),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      icon: const Icon(Icons.login),
                      label: const Text('登录汽水音乐'),
                      onPressed: () async {
                        final done = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(builder: (_) => const LoginPage()),
                        );
                        if (done == true) {
                          widget.onSettingsChanged();
                          _load(force: true);
                        }
                      },
                    ),
                  ],
                ),
              )
            else ...[
              Card(
                margin: const EdgeInsets.all(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      ClipOval(
                        child: CoverImage(
                          url: _account?.avatarUrl ?? '',
                          size: 56,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    _account?.nickname ?? '已登录',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (_account?.vip == true) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.amber.shade700,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'VIP',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (_loading)
                              const Text('加载中…',
                                  style: TextStyle(fontSize: 12))
                            else if (_error != null)
                              Text(
                                _error!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.error,
                                ),
                              )
                            else
                              Text(
                                'ID ${_account?.userId ?? ''}',
                                style: const TextStyle(fontSize: 12),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '退出登录',
                        icon: const Icon(Icons.logout),
                        onPressed: _logout,
                      ),
                    ],
                  ),
                ),
              ),
            ],
            // ---- App 全局内容：与音源/登录状态无关 ----
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text('全局内容', style: Theme.of(context).textTheme.titleSmall),
            ),
            // 我喜欢的音乐（本机红心）：跨音源共享，任何音源/未登录都可
            // 进入。首页汽水形态的入口是抖音账号喜欢（服务器），数据独立。
            ListenableBuilder(
              listenable: likedStore,
              builder: (context, _) => ListTile(
                leading: const Icon(Icons.favorite),
                title: const Text('我喜欢的音乐'),
                  subtitle: Text(likedStore.count > 0
                      ? '本机红心 · ${likedStore.count} 首'
                      : '本机红心 · 播放页点红心收藏'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PlaylistPage(
                      title: '我喜欢的音乐',
                      playlistId: '',
                      liked: true,
                    ),
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.leaderboard_outlined),
              title: const Text('听歌排行'),
              subtitle: const Text('本机播放统计 · 最近一周 / 全部'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const RankingPage(),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('最近播放'),
              subtitle: const Text('本机播放历史 · 所有音源共用'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const RecentPage(),
                ),
              ),
            ),
            if (settings.hasCookie) ...[
              if (_collected.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('收藏的歌单（${_collected.length}）',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                ..._collected.map(
                  (playlist) => ListTile(
                    leading: CoverImage(url: playlist.cover, size: 48),
                    title: Text(playlist.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text([
                      '${playlist.trackCount} 首',
                      if (playlist.creator.isNotEmpty) playlist.creator,
                    ].join(' · ')),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PlaylistPage(
                          title: playlist.title,
                          playlistId: playlist.id,
                          item: playlist,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              if (_collectedAlbums.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('收藏的专辑（${_collectedAlbums.length}）',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                ..._collectedAlbums.map(
                  (album) => ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CoverImage(url: album.cover, size: 48),
                    ),
                    title: Text(album.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text([
                      if (album.artist.isNotEmpty) album.artist,
                      if (album.trackCount > 0) '${album.trackCount} 首',
                    ].join(' · ')),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AlbumPage(
                          albumId: album.id,
                          title: album.title,
                          artist: album.artist,
                          cover: album.cover,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
