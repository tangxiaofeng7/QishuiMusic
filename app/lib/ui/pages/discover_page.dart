import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/errors.dart';
import '../../core/lx_catalog.dart';
import '../../core/lx_runtime.dart';
import '../../core/logging.dart';
import '../../core/models.dart';
import '../../core/page_cache.dart';
import '../../core/source.dart';
import '../../main.dart';
import '../widgets/playlist_card.dart';
import 'login_page.dart';
import 'lx_sources_page.dart';
import 'playlist_page.dart';
import 'platform_tracks_page.dart';
import 'search_page.dart';

/// 发现页：按播放音源分流。
/// * 汽水：排行榜 + 推荐歌单 + 歌单广场（官方 discover/mix 内容流）；
/// * 其他音源：平台榜单卡（关键词驱动的平台搜索流）+ 可用脚本源状态。
///
/// 顶部搜索栏随本页（原独立搜索 Tab 已改为播放器 Tab，对齐官方汽水
/// 音乐动线：搜索入口在发现页）。
class DiscoverPage extends StatelessWidget {
  const DiscoverPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sourceStore,
      builder: (context, _) => sourceStore.isLx
          ? const LxDiscoverPage()
          : const SodaDiscoverPage(),
    );
  }
}

/// 顶部搜索入口：假输入框，点进搜索页并直接弹键盘。
class _SearchEntry extends StatelessWidget {
  const _SearchEntry({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const SearchPage(autofocus: true),
      )),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Row(
          children: [
            Icon(Icons.search, size: 20, color: scheme.outline),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: scheme.outline),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 汽水发现页（原内容：排行榜 + 推荐歌单 + 歌单广场）。
///
/// 数据源：
/// * 排行榜：`discovery_chart` 场景流（一个 block = 一个榜单，本质是歌单）
/// * 推荐歌单：`/luna/me/playlist/recommend`
/// * 歌单广场：`discovery_playlist` 场景流（游标分页，无限滚动）
class SodaDiscoverPage extends StatefulWidget {
  const SodaDiscoverPage({super.key});

  @override
  State<SodaDiscoverPage> createState() => _SodaDiscoverPageState();
}

class _SodaDiscoverPageState extends State<SodaDiscoverPage> {
  // 排行榜
  final List<ChartEntry> _charts = [];
  bool _chartsLoading = true;
  String? _chartsError;

  // 推荐歌单
  final List<PlaylistItem> _recommend = [];

  // 歌单广场（分页）
  final List<PlaylistItem> _square = [];
  final Set<String> _squareSeenIds = {};
  final ScrollController _scroll = ScrollController();
  String _squareCursor = '';
  bool _squareHasMore = true;
  bool _squareLoading = false;
  String? _squareError;

  /// 下一次广场回包是「第一页」：整体替换（覆盖 SWR 缓存回填）而非追加。
  bool _squareFirstPage = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600 &&
          !_squareLoading &&
          _squareHasMore) {
        _loadSquare();
      }
    });
    _restoreFromCache();
    _reload();
  }

  /// 首屏 SWR：上次内容先上屏（秒开），网络刷新整块覆盖。
  Future<void> _restoreFromCache() async {
    final value = await PageCache.readJson('discover');
    if (value == null || !mounted) return;
    if (_charts.isNotEmpty || _square.isNotEmpty) return; // 网络更快，不覆盖
    final charts = (value['charts'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => ChartEntry.fromCache(Map<String, dynamic>.from(item)))
        .toList();
    final tracksFilled = charts.isNotEmpty;
    setState(() {
      if (tracksFilled) {
        _charts
          ..clear()
          ..addAll(charts);
        _chartsLoading = false;
      }
      _recommend
        ..clear()
        ..addAll((value['recommend'] as List? ?? const [])
            .whereType<Map>()
            .map((item) =>
                PlaylistItem.fromJson(Map<String, dynamic>.from(item)))
            .toList());
      _square
        ..clear()
        ..addAll((value['square'] as List? ?? const [])
            .whereType<Map>()
            .map((item) =>
                PlaylistItem.fromJson(Map<String, dynamic>.from(item)))
            .toList());
      for (final item in _square) {
        if (item.id.isNotEmpty) _squareSeenIds.add(item.id);
      }
    });
  }

  Future<void> _persistDiscover() async {
    await PageCache.writeJson('discover', {
      'charts': _charts.map((item) => item.toCache()).toList(),
      'recommend': _recommend.map((item) => item.toJson()).toList(),
      'square': _square.take(30).map((item) => item.toJson()).toList(),
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    if (!settings.hasCookie) return; // 未登录展示引导卡
    setState(() {
      _chartsLoading = _charts.isEmpty;
      _squareError = null;
      _square.clear();
      _squareSeenIds.clear();
      _squareHasMore = true;
      _squareLoading = true;
      _squareFirstPage = true;
    });
    await Future.wait([
      _loadCharts(),
      _loadRecommend(),
      _square.isEmpty ? _loadSquare() : Future.value(),
    ]);
  }

  Future<void> _loadCharts() async {
    try {
      final page = await Api.discoverMix('discovery_chart', count: 30);
      final entries = page.blocks
          .map(ChartEntry.fromBlock)
          .whereType<ChartEntry>()
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        // 榜单 block 无 title 字段时用拍平的歌单列表兜底
        _charts
          ..clear()
          ..addAll(entries.isNotEmpty
              ? entries
              : page.playlists
                  .map((item) => ChartEntry(
                      title: item.title, playlist: item))
                  .toList(growable: false));
        _chartsError = null;
      });
      unawaited(_persistDiscover());
    } catch (error) {
      appLog('discover: 排行榜加载失败: $error');
      if (mounted && _charts.isEmpty) {
        setState(() => _chartsError = friendlyError(error));
      }
    } finally {
      if (mounted) setState(() => _chartsLoading = false);
    }
  }

  Future<void> _loadRecommend() async {
    try {
      final playlists = await Api.recommendPlaylists();
      if (!mounted) return;
      setState(() {
        _recommend
          ..clear()
          ..addAll(playlists.take(12));
      });
      unawaited(_persistDiscover());
    } catch (error) {
      // 推荐位失败不阻塞页面（常见于冷账号限流）
      appLog('discover: 推荐歌单失败: $error');
      if (mounted) {
        setState(() => _recommend.clear());
      }
    }
  }

  Future<void> _loadSquare() async {
    if (_squareLoading && _square.isNotEmpty) return;
    setState(() {
      _squareLoading = true;
      if (_square.isEmpty) _squareError = null;
    });
    final replaceFirstPage = _squareFirstPage;
    _squareFirstPage = false;
    try {
      final page = await Api.discoverMix('discovery_playlist',
          cursor: _squareCursor, count: 20);
      if (!mounted) return;
      // 实测该场景回包没有翻页游标（has_more 恒真，重复请求内容轮换）：
      // 分页 = 同参重拉 + 按 id 去重（Set.add 返回 true = 新增）；一页无新增视为到尽头。
      final fresh = page.playlists
          .where((item) => item.id.isNotEmpty && _squareSeenIds.add(item.id))
          .toList(growable: false);
      setState(() {
        if (replaceFirstPage) _square.clear(); // 覆盖 SWR 缓存回填
        _square.addAll(fresh);
        _squareCursor = page.nextCursor;
        _squareHasMore = page.hasMore && fresh.isNotEmpty;
        _squareError = null;
      });
      if (replaceFirstPage) unawaited(_persistDiscover());
    } catch (error) {
      if (mounted && _square.isEmpty) {
        setState(() => _squareError = friendlyError(error));
      }
    } finally {
      if (mounted) setState(() => _squareLoading = false);
    }
  }

  void _openPlaylist(PlaylistItem item) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlaylistPage(
        title: item.title,
        playlistId: item.id,
        item: item,
              ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: _SearchEntry(hint: '搜索歌曲 / 音乐人 / 专辑 / 歌单'),
      ),
      body: !settings.hasCookie
          ? _loginGuide(scheme)
          : RefreshIndicator(
              onRefresh: _reload,
              child: CustomScrollView(
                controller: _scroll,
                slivers: [
                  _sectionTitle('排行榜'),
                  _chartsSection(scheme),
                  if (_recommend.isNotEmpty) ...[
                    _sectionTitle('为你推荐'),
                    _recommendSection(scheme),
                  ],
                  _sectionTitle('歌单广场'),
                  _squareSection(scheme),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                ],
              ),
            ),
    );
  }

  Widget _loginGuide(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.explore_outlined, size: 56, color: scheme.outline),
            const SizedBox(height: 12),
            Text('登录后解锁排行榜与歌单广场', style: TextStyle(color: scheme.outline)),
            const SizedBox(height: 14),
            FilledButton.tonal(
              onPressed: () async {
                final done = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                );
                if (done == true && mounted) _reload();
              },
              child: const Text('去登录'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Text(
          text,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _chartsSection(ColorScheme scheme) {
    if (_chartsLoading) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    if (_charts.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            _chartsError ?? '暂无榜单内容',
            style: TextStyle(fontSize: 12.5, color: scheme.outline),
          ),
        ),
      );
    }
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 132,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _charts.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final chart = _charts[index];
            return PlaylistCard(
              cover: chart.playlist.cover,
              title: chart.title,
              subtitle: '${chart.playlist.trackCount} 首',
              width: 112,
              onTap: () => _openPlaylist(chart.playlist),
              rankBadge: index < 3 ? '${index + 1}' : null,
            );
          },
        ),
      ),
    );
  }

  Widget _recommendSection(ColorScheme scheme) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 172,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _recommend.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final item = _recommend[index];
            return PlaylistCard(
              cover: item.cover,
              title: item.title,
              subtitle: item.trackCount > 0 ? '${item.trackCount} 首' : '',
              width: 118,
              onTap: () => _openPlaylist(item),
            );
          },
        ),
      ),
    );
  }

  Widget _squareSection(ColorScheme scheme) {
    if (_square.isEmpty && _squareError != null) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_squareError!),
              ),
              FilledButton.tonal(
                onPressed: _loadSquare,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_square.isEmpty && _squareLoading) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index >= _square.length) {
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
          final item = _square[index];
          return PlaylistCard(
            cover: item.cover,
            title: item.title,
            subtitle: item.trackCount > 0 ? '${item.trackCount} 首' : '',
            width: double.infinity,
            onTap: () => _openPlaylist(item),
          );
        },
        childCount: _square.length + (_squareHasMore ? 1 : 0),
      ),
    );
  }
}

/// 其他音源发现页：当前平台的榜单卡（kg/wy/tx 免签真实榜单、kw 关键词
/// 搜索流，目录随音源换装）+ 可用脚本源状态。
class LxDiscoverPage extends StatefulWidget {
  const LxDiscoverPage({super.key});

  @override
  State<LxDiscoverPage> createState() => _LxDiscoverPageState();
}

class _LxDiscoverPageState extends State<LxDiscoverPage> {
  int _lxReady = 0;
  int _lxTotal = 0;

  @override
  void initState() {
    super.initState();
    // 平台可在首页/音源页切换：跟随换装榜单目录（与 LxHomePage 同一套联动）
    sourceStore.addListener(_onSourceChanged);
    _refreshLx();
  }

  void _onSourceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    sourceStore.removeListener(_onSourceChanged);
    super.dispose();
  }

  Future<void> _refreshLx() async {
    await LxRuntime.instance.ensureStarted();
    await LxRuntime.instance.refreshStatus();
    if (mounted) {
      setState(() {
        final hidden = settings.lxHiddenScripts;
        final visible =
            LxRuntime.instance.scripts.where((s) => !hidden.contains(s.id));
        _lxTotal = visible.length;
        _lxReady = visible.where((s) => s.ready).length;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: _SearchEntry(hint: '在${lxPlatformName(sourceStore.platform)}搜歌曲'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
            child: Text(
              '${lxPlatformName(sourceStore.platform)} · 榜单',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          // 榜单卡网格：只随当前音源平台展示（点击进入平台曲目页），
          // kg/wy/tx 为免签真实榜单，kw 为关键词搜索流
          Builder(
            builder: (builderContext) {
              final platform = sourceStore.platform;
              return GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 2.4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final chart in lxCatalogFor(platform))
                    _ChartCard(
                      title: chart.title,
                      subtitle: platform == 'kw'
                          ? '关键词「${chart.id}」搜索流'
                          : '官方榜单 · 实时更新',
                      onTap: () => Navigator.of(builderContext).push(
                        MaterialPageRoute<void>(
                          builder: (_) => PlatformTracksPage(
                            platform: platform,
                            chartId: chart.id,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          // 取流脚本状态卡：就绪脚本 x/y + 管理入口
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: Icon(
                _lxReady > 0 ? Icons.auto_awesome : Icons.error_outline,
                color: _lxReady > 0 ? scheme.primary : scheme.error,
              ),
              title: const Text('取流脚本'),
              subtitle: Text(
                _lxTotal == 0
                    ? '正在初始化…'
                    : '$_lxReady/$_lxTotal 个就绪 · 播放整曲依赖脚本出链',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => OtherSourcesPage(
                      onSettingsChanged: () {},
                    ),
                  ),
                );
                // 管理页里可能启停了脚本：回来刷新就绪计数
                await _refreshLx();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              '当前音源的曲库来自${lxPlatformName(sourceStore.platform)}免签接口'
              '（酷我无免签榜单、以关键词搜索流兜底）；播放取流由就绪的取流脚本完成。',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

/// 榜单卡：渐变底 + 标题 + 副标题。
class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      color: scheme.surfaceContainerHigh,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  Icon(Icons.leaderboard, size: 18, color: scheme.primary),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.outline,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
