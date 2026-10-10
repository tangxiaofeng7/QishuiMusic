import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../core/api.dart';
import '../../core/errors.dart';
import '../../core/lx_catalog.dart';
import '../../core/lx_runtime.dart';
import '../../core/logging.dart';
import '../../core/models.dart';
import '../../core/page_cache.dart';
import '../../core/source.dart';
import '../../core/speed.dart';
import '../../main.dart';
import '../widgets/cover.dart';
import '../widgets/playlist_card.dart';
import '../widgets/skeleton.dart';
import '../widgets/track_tile.dart';
import 'followed_artists_page.dart';
import 'login_page.dart';
import '../../core/lx_speed_test.dart';
import 'music_wall_page.dart';
import 'playlist_page.dart';
import 'platform_tracks_page.dart';
import 'radio_page.dart';

/// 首页：按播放音源分流（切换音源即切换整个首页形态）。
/// * 汽水：汽水FM 横幅 → 个人内容入口（音乐墙/抖音收藏/关注艺人）→
///   场景模式大卡轮播 → 为你推荐（歌单卡）→ 官方推荐队列；
/// * 其他音源：平台榜单卡条（kg/wy/tx 免签真榜单，酷我为关键词流，
///   目录随平台动态换装）→ 榜单曲目流（LX 脚本只做取流，
///   曲库来自 App 的免签平台接口）。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sourceStore,
      builder: (context, _) => sourceStore.isLx
          ? const LxHomePage()
          : const SodaHomePage(),
    );
  }
}

/// 首页顶部音源切换面板（汽水/平台两种首页形态共用）：
/// * 汽水账号（登录曲库）；
/// * 其他音源 = 取流脚本（对齐 lx-music「音源即脚本」：就绪脚本
///   声明什么就罗列什么，不写死；从推荐音源导入后在此选用）；
/// * 曲库平台（酷我/网易云/酷狗/QQ，App 免签榜单/搜索的维度）在选定
///   脚本后收敛为其支持的平台。
Future<void> showHomeSourceSheet(BuildContext context) async {
  await LxRuntime.instance.ensureStarted();
  await LxRuntime.instance.refreshStatus();
  if (!context.mounted) return;
  final scheme = Theme.of(context).colorScheme;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final hidden = settings.lxHiddenScripts;
      final disabled = settings.lxDisabledScripts;
      // 就绪且有可用平台的脚本 = 可选音源；速度快的在前
      final readyScripts = LxRuntime.instance.scripts
          .where((s) =>
              !hidden.contains(s.id) &&
              !disabled.contains(s.id) &&
              s.ready &&
              LxRuntime.instance.platformsOfScript(s).isNotEmpty)
          .toList()
        ..sort((a, b) {
          int ms(LxScriptInfo s) {
            final result = speedStore.of(lxSpeedKey(s.id));
            return result != null && result.ok ? result.ms : 1 << 30;
          }
          return ms(a).compareTo(ms(b));
        });
      // 曲库平台与激活脚本解耦：免签曲库/搜索支持的平台全部可选
      final platforms = LxRuntime.searchSupportedPlatforms;
      final activeScript = settings.lxScript;
      // 激活脚本未就绪（冷启动校验窗口）或校验失败时固定置顶显示：
      // 否则它从列表"消失"，用户以为音源选择丢了
      final activeInfo = activeScript.isEmpty
          ? null
          : LxRuntime.instance.scriptById(activeScript);
      final activePending = activeInfo != null &&
          !hidden.contains(activeScript) &&
          !disabled.contains(activeScript) &&
          !readyScripts.any((s) => s.id == activeScript);
      String scriptSubtitle(LxScriptInfo script) {
        final platforms =
            LxRuntime.instance.platformsOfScript(script).map(lxPlatformName);
        final qualitys = script.sources.values
            .expand((list) => list)
            .toSet()
            .toList()
          ..sort();
        return [
          platforms.join('/'),
          if (qualitys.isNotEmpty) qualitys.join('/'),
          if (script.version.isNotEmpty) 'v${script.version}',
        ].join(' · ');
      }

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '切换音源',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.account_circle),
                title: const Text('汽水账号'),
                subtitle: const Text(
                  '账号曲库（VIP 权益 / 音质限免）',
                  style: TextStyle(fontSize: 12),
                ),
                trailing: settings.sourceMode == 'default'
                    ? Icon(Icons.check_circle, color: scheme.primary)
                    : null,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  sourceStore.switchTo('default');
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '其他音源 · 取流脚本',
                    style: Theme.of(sheetContext)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              if (activePending)
                ListTile(
                  dense: true,
                  leading: const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: Text(activeInfo.name),
                  subtitle: Text(
                    activeInfo.error.isEmpty
                        ? '当前音源 · 正在校验初始化，点按立即激活'
                        : '当前音源 · 校验未通过：${activeInfo.error}',
                    style: const TextStyle(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Icon(Icons.check_circle, color: scheme.primary),
                  // 未就绪也允许激活：切 lx 模式并立即初始化（否则默认
                  // 模式下无人加载它，用户被锁在汽水音源）
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    sourceStore.switchTo('lx');
                    sourceStore.warmActiveScript();
                  },
                ),
              for (final script in readyScripts)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.extension),
                  title: Text(script.name),
                  subtitle: Text(
                    scriptSubtitle(script),
                    style: const TextStyle(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: settings.sourceMode == 'lx' &&
                          activeScript == script.id
                      ? Icon(Icons.check_circle, color: scheme.primary)
                      : null,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    sourceStore.switchTo('lx');
                    sourceStore.switchScript(script.id);
                  },
                ),
              if (readyScripts.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '暂无脚本：到「设置 → 播放音源 → 管理取流脚本 → '
                      '推荐音源」一键导入',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              // 曲库平台（榜单/搜索维度，与激活脚本解耦，自由切换）
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '曲库平台',
                    style: Theme.of(sheetContext)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final item in platforms)
                      ChoiceChip(
                        label: Text(lxPlatformName(item)),
                        selected: settings.sourceMode == 'lx' &&
                            settings.lxPlatform == item,
                        onSelected: (_) {
                          Navigator.of(sheetContext).pop();
                          sourceStore.switchTo('lx');
                          sourceStore.switchPlatform(item);
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 首页头部 FM 横幅：主题色渐变 + 无限电台入口。
class _FmBanner extends StatelessWidget {
  const _FmBanner({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Material(
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        color: scheme.primaryContainer,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.radio, size: 20, color: scheme.onPrimary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('汽水FM · 无限畅听',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: scheme.onPrimaryContainer,
                          )),
                      const SizedBox(height: 2),
                      Text('风格电台自动换歌，不重样',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onPrimaryContainer
                                .withValues(alpha: 0.75),
                          )),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.onPrimaryContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 汽水个人内容入口（原「我的」页三入口，仅汽水音源显示）：
/// 音乐墙 / 抖音收藏的音乐 / 我关注的艺人。
class _PersonalEntries extends StatelessWidget {
  const _PersonalEntries();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget entry(IconData icon, String title, VoidCallback onTap) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Material(
              borderRadius: BorderRadius.circular(12),
              color: scheme.surfaceContainerHigh,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 22, color: scheme.primary),
                      const SizedBox(height: 6),
                      Text(
                        title,
                        style: const TextStyle(fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          entry(Icons.grid_view, '音乐墙', () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => const MusicWallPage()),
              )),
          entry(Icons.music_video, '抖音收藏', () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const PlaylistPage(
                  title: '抖音收藏的音乐',
                  playlistId: '',
                  douyinFavorites: true,
                ),
              ),
            );
          }),
          entry(Icons.person_search, '关注艺人', () =>
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => const FollowedArtistsPage()),
              )),
        ],
      ),
    );
  }
}

/// 场景大卡：官方接口的 cover 做全出血背景 + 底部渐变遮罩。
/// 缺图/加载失败回落品牌渐变，保证卡片任何状态下都有观感。
class _SceneCard extends StatelessWidget {
  const _SceneCard({
    required this.scene,
    required this.selected,
    required this.onTap,
    required this.width,
  });

  final SceneItem scene;
  final bool selected;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: width,
      height: 104,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        // 品牌渐变兜底（cover 缺失/加载失败时就是卡片底色）
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.9),
            scheme.tertiary.withValues(alpha: 0.75),
          ],
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (scene.cover.trim().isNotEmpty)
            FutureBuilder<File?>(
              future: resolveCoverFile(scene.cover),
              builder: (context, snapshot) {
                final file = snapshot.data;
                if (file == null || !file.existsSync()) {
                  return const SizedBox.shrink();
                }
                return Image.file(
                  file,
                  fit: BoxFit.cover,
                  // 168pt 卡片按 2x 解码即可（原图 512px 整图解码浪费）
                  cacheWidth: 336,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                );
              },
            ),
          // 底部渐变遮罩：保证白字在任何封面下可读
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black54],
                stops: [0.45, 1],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(scene.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    )),
                const SizedBox(height: 2),
                Text(
                  selected ? '正在收听' : '场景歌单 · 点击切换',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
          if (selected)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.check,
                    size: 14, color: scheme.primary),
              ),
            ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: GestureDetector(
        onTap: onTap,
        child: selected
            ? Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.primary, width: 2),
                ),
                child: card,
              )
            : card,
      ),
    );
  }
}

/// 汽水音源首页（原首页内容 + 个人内容入口）。
class SodaHomePage extends StatefulWidget {
  const SodaHomePage({super.key});

  @override
  State<SodaHomePage> createState() => _SodaHomePageState();
}

class _SodaHomePageState extends State<SodaHomePage> {
  final ScrollController _scroll = ScrollController();
  List<SceneItem> _scenes = [];
  final List<Track> _tracks = [];
  SceneItem? _scene;

  /// 首页「为你推荐」歌单（登录后；静默加载，失败隐藏区块）。
  List<PlaylistItem> _recommend = [];
  int _fetchCounter = 0;
  int _didFirstUseTime = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _fallback = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600 && !_loading && _hasMore) {
        _loadMore();
      }
    });
    _restoreFromCache();
    _reload();
  }

  /// 首屏 SWR：先用上次的内容秒开（官方客户端行为），网络刷新成功后覆盖。
  /// 缓存回填的 tracks 会在网络第一页回来时被整体替换（见 _loadMore）。
  Future<void> _restoreFromCache() async {
    final value = await PageCache.readJson('home');
    if (value == null || !mounted) return;
    if (_tracks.isNotEmpty || _scenes.isNotEmpty) return; // 网络更快，不覆盖
    final tracks = parseTracks(value['tracks']);
    if (tracks.isEmpty && (value['scenes'] as List? ?? const []).isEmpty) {
      return;
    }
    setState(() {
      _scenes = (value['scenes'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => SceneItem.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      _recommend = (value['recommend'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => PlaylistItem.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      _tracks.addAll(tracks);
      _fetchCounter = (value['fetchCounter'] as num?)?.toInt() ?? 0;
      _didFirstUseTime = (value['didFirstUseTime'] as num?)?.toInt() ?? 0;
      _hasMore = value['hasMore'] != false;
    });
  }

  Future<void> _persistHome() async {
    await PageCache.writeJson('home', {
      'scenes': _scenes.map((item) => item.toJson()).toList(),
      'recommend': _recommend.map((item) => item.toJson()).toList(),
      'tracks': _tracks.take(30).map((item) => item.toJson()).toList(),
      'fetchCounter': _fetchCounter,
      'didFirstUseTime': _didFirstUseTime,
      'hasMore': _hasMore,
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _tracks.clear();
      _fetchCounter = 0;
      _didFirstUseTime = 0;
      _hasMore = true;
      _error = null;
      _fallback = false;
    });
    // 三路数据互不依赖：并行拉取（原先「场景→推荐流」串行，首页首屏
    // 白白多等一整个请求往返）。
    await Future.wait([
      _loadScenes(),
      _loadRecommend(),
      _loadMore(),
    ]);
  }

  Future<void> _loadScenes() async {
    try {
      final scenes = await Api.scenes();
      if (mounted) {
        setState(() => _scenes = scenes);
        unawaited(_persistHome());
      }
    } catch (error) {
      // 听歌模式失败不阻塞推荐流
      debugPrint('听歌模式加载失败: $error');
    }
  }

  Future<void> _loadRecommend() async {
    if (!settings.hasCookie) return;
    try {
      final playlists = await Api.recommendPlaylists();
      if (mounted) {
        setState(() => _recommend = playlists.take(8).toList());
        unawaited(_persistHome());
      }
    } catch (error) {
      // 推荐位失败静默隐藏（发现页还有完整版）
      debugPrint('首页推荐歌单失败（忽略）: $error');
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    final isFirstPage = _fetchCounter == 0;
    try {
      final page = await Api.feed(
        fetchCounter: _fetchCounter,
        didFirstUseTime: _didFirstUseTime,
        sceneModeId: _scene?.sceneModeId,
        subQueueType: _scene?.subQueueType,
      );
      if (!mounted) return;
      setState(() {
        // 第一页整体替换（覆盖 SWR 缓存回填的旧内容），后续页追加
        if (isFirstPage) _tracks.clear();
        _tracks.addAll(page.tracks);
        _fetchCounter = page.fetchCounter;
        _didFirstUseTime = page.didFirstUseTime;
        _hasMore = page.hasMore && page.tracks.isNotEmpty;
        _error = null;
        _fallback = false;
      });
      if (isFirstPage) unawaited(_persistHome());
    } catch (error) {
      // 个性化推荐被服务端签名门禁拒绝（如 1000006）时，降级为热门搜索
      // 结果（匿名可用）；场景卡顺势充当搜索分类入口。
      if (_tracks.isEmpty) {
        try {
          final keyword = _scene?.text ?? '热门';
          final results = await Api.searchAll(keyword);
          if (!mounted) return;
          if (results.tracks.isNotEmpty) {
            setState(() {
              _tracks.addAll(results.tracks.take(30));
              _hasMore = false;
              _fallback = true;
              _error = null;
            });
            return;
          }
        } catch (_) {
          // 降级也失败则展示原始错误
        }
      }
      // 网络失败但缓存内容仍在屏：不打断浏览，只记录错误
      if (mounted && _tracks.isEmpty) {
        setState(() => _error = friendlyError(error));
      } else if (mounted && !isFirstPage) {
        setState(() => _hasMore = false); // 翻页失败：停在当前内容
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickScene(SceneItem? scene) async {
    setState(() => _scene = scene);
    await _reload();
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
    return Scaffold(
      appBar: AppBar(
        // 标题用品牌名/场景名，不再叫「为你推荐」——正文里同名区块头
        // 已经存在，App Bar 重复一次读起来像两个页面。
        title: Text(_scene?.text ?? kAppName),
        actions: [
          // 音源切换（与平台音源首页共用同一面板，切走即换整个首页形态）
          IconButton(
            tooltip: '切换音源',
            icon: const Icon(Icons.swap_vert_circle_outlined),
            onPressed: () => showHomeSourceSheet(context),
          ),
          IconButton(
            tooltip: '播放全部',
            icon: const Icon(Icons.play_circle),
            onPressed: _tracks.isEmpty
                ? null
                : () => player.playQueue(_tracks, 0),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            // 汽水FM 入口（对齐官方首页头部玩法：无限电台）
            if (settings.hasCookie)
              SliverToBoxAdapter(
                child: _FmBanner(onOpen: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const RadioPage()),
                    )),
              ),
            // 个人内容入口（音乐墙/抖音收藏/关注艺人；登录后才有内容）
            if (settings.hasCookie)
              const SliverToBoxAdapter(child: _PersonalEntries()),
            // 我喜欢的音乐（抖音/汽水账号侧喜欢列表，纯服务器数据；
            // 需登录，布局对齐「我的 → 最近播放」的 ListTile 形态）。
            // 本机红心是另一份数据，全局入口在「我的」页。
            if (settings.hasCookie)
              SliverToBoxAdapter(
                child: ListTile(
                  leading: const Icon(Icons.favorite),
                  title: const Text('我喜欢的音乐'),
                  subtitle: const Text('抖音账号喜欢 · 云端同步'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const PlaylistPage(
                        title: '我喜欢的音乐',
                        playlistId: '',
                        accountLiked: true,
                      ),
                    ),
                  ),
                ),
              ),
            // 场景模式大卡轮播（对齐官方首页形态）
            if (_scenes.isNotEmpty)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 112,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _scenes.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final scene = _scenes[index];
                      final selected = _scene?.text == scene.text;
                      return _SceneCard(
                        scene: scene,
                        selected: selected,
                        width: 168,
                        onTap: () =>
                            _pickScene(selected ? null : scene),
                      );
                    },
                  ),
                ),
              ),
            // 为你推荐（官方推荐歌单，点击直达歌单页）
            if (_recommend.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Text('为你推荐',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
              ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 178,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _recommend.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, index) => PlaylistCard(
                      cover: _recommend[index].cover,
                      title: _recommend[index].title,
                      subtitle: _recommend[index].trackCount > 0
                          ? '${_recommend[index].trackCount} 首'
                          : '',
                      width: 136,
                      onTap: () => _openPlaylist(_recommend[index]),
                    ),
                  ),
                ),
              ),
            ],
            if (_fallback)
              SliverToBoxAdapter(
                child: Card(
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 18, color: Theme.of(context).colorScheme.outline),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '个性化推荐暂不可用（服务端签名校验），已为你展示'
                            '「${_scene?.text ?? '热门'}」搜索结果；点上方场景卡可切换分类',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (!settings.hasCookie)
              SliverToBoxAdapter(
                child: Card(
                  margin: const EdgeInsets.all(12),
                  child: ListTile(
                    leading: const Icon(Icons.login),
                    title: const Text('未登录'),
                    subtitle: const Text('登录后可听推荐队列与我的音乐，点此去登录'),
                    onTap: () async {
                      final done = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                            builder: (_) => const LoginPage()),
                      );
                      if (done == true && mounted) setState(() {});
                    },
                  ),
                ),
              ),
            if (_error != null && _tracks.isEmpty)
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
                        onPressed: _reload,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              )
            else if (_loading && _tracks.isEmpty)
              // 首载骨架屏（下拉刷新/滚动加载仍用小菊花）
              const SliverFillRemaining(
                hasScrollBody: false,
                child: SkeletonBody(count: 9),
              )
            else
              SliverList.builder(
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
          ],
        ),
      ),
    );
  }
}

/// 其他音源首页：平台榜单卡条 + 榜单曲目流。
/// 榜单目录随音源换装（lxCatalogFor）：kg/wy/tx 为免签真实榜单，
/// kw 无免签榜单接口、以关键词搜索流兜底。
class LxHomePage extends StatefulWidget {
  const LxHomePage({super.key});

  @override
  State<LxHomePage> createState() => _LxHomePageState();
}

class _LxHomePageState extends State<LxHomePage> {
  final ScrollController _scroll = ScrollController();
  final List<Track> _tracks = [];
  String _platform = 'kw';
  // 当前榜单卡（真实榜单 id 或酷我关键词），目录随平台换装
  LxChart _chart = lxScenes.first;
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;
  // 首页加载自动重试计数（免签榜单接口冷启动偶发空回包/No route to host，
  // 不重试的话首页会停在空白态，直到用户手动刷新）
  int _retries = 0;
  // 加载代际：每次切源/重载递增。在途旧请求的回包按代际作废——否则
  // 切平台时新目录的加载会被在途请求的 _loading 互斥吞掉（表现为首页
  // 空白，旧平台的回包落地后才恢复），代际令牌保证永远以最后一次切换为准
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    _platform = settings.lxPlatform;
    _chart = lxCatalogFor(_platform).first;
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600 && !_loading && _hasMore) {
        _loadMore();
      }
    });
    sourceStore.addListener(_onSourceStoreChanged);
    _restoreFromCache();
    _loadMore();
  }

  /// 平台可在别处切换（发现/搜索页）：跟随 sourceStore 同步重拉。
  /// 榜单一并重置回该平台目录首个——切换音源意味着换一套内容形态，
  /// 残留上个平台的榜单（如酷狗 TOP500）会让用户以为切换没生效。
  /// 脚本切换（平台不变）也 setState：标题/面板状态即时换装。
  void _onSourceStoreChanged() {
    if (!mounted) return;
    final platform = sourceStore.platform;
    if (platform != _platform) {
      _platform = platform;
      _chart = lxCatalogFor(platform).first;
      _reload();
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    sourceStore.removeListener(_onSourceStoreChanged);
    _scroll.dispose();
    super.dispose();
  }

  /// 首屏 SWR（按平台隔离缓存键）。
  Future<void> _restoreFromCache() async {
    final platform = _platform;
    final value = await PageCache.readJson('home-lx-$platform');
    // 读取期间用户已切平台：缓存作废，不回填
    if (value == null || !mounted || platform != _platform) return;
    if (_tracks.isNotEmpty) return;
    final chartId = value['chartId']?.toString() ?? '';
    // 缓存的榜单可能已不在当前目录（榜单目录调整）：回落首个
    final chart = lxCatalogFor(_platform)
        .where((item) => item.id == chartId)
        .firstOrNull;
    final tracks = parseTracks(value['tracks']);
    if (tracks.isEmpty || chart == null) return;
    setState(() {
      _chart = chart;
      _tracks.addAll(tracks);
      _hasMore = false; // 缓存只存首页，翻页由网络重拉
    });
  }

  Future<void> _persist() async {
    if (_page != 1) return; // 只存第一页
    await PageCache.writeJson('home-lx-$_platform', {
      'chartId': _chart.id,
      'tracks': _tracks.take(30).map((item) => item.toJson()).toList(),
    });
  }

  Future<void> _reload() async {
    _loadGen++; // 作废在途请求（回包到达后按代际丢弃）
    setState(() {
      _tracks.clear();
      _page = 0;
      _hasMore = true;
      _error = null;
      _retries = 0;
    });
    await _loadMore(force: true);
  }

  /// [force]：绕过在途互斥直接开新加载（切源/下拉刷新）。
  /// 旧请求因代际已变，其回包与 finally 都不再触碰 UI。
  Future<void> _loadMore({bool force = false}) async {
    if ((_loading && !force) || !_hasMore) return;
    final gen = ++_loadGen;
    setState(() => _loading = true);
    try {
      // 首页（page 0）失败或空回包自动重试：免签榜单接口冷启动第一击
      // 偶发空回包/No route to host（实测网易云常见），重试即恢复；
      // 不重试的话首页会一直停在空白态等用户手动刷新
      while (true) {
        try {
          final result = await Api.chartTracks(
            _platform,
            _chart.id,
            page: _page + 1,
          );
          if (!mounted || gen != _loadGen) return; // 已被新加载取代
          if (result.tracks.isNotEmpty || _page > 0 || _retries >= 2) {
            final seen = _tracks.map((track) => track.id).toSet();
            setState(() {
              if (_page == 0) _tracks.clear(); // 覆盖 SWR 缓存回填
              _tracks.addAll(result.tracks.where((t) => seen.add(t.id)));
              _page += 1;
              _hasMore = result.hasMore;
              _error = null;
            });
            // 空结果不落缓存：避免用空榜覆盖上一次的好缓存
            if (_tracks.isNotEmpty) unawaited(_persist());
            return;
          }
          throw StateError('榜单回包为空');
        } catch (error) {
          if (!mounted || gen != _loadGen) return; // 已被新加载取代
          if (_page > 0 || _retries >= 2) rethrow;
          _retries += 1;
          appLog('home-lx: 榜单加载失败（$_platform/${_chart.id}），'
              '自动重试 #$_retries: $error');
          await Future<void>.delayed(const Duration(milliseconds: 800));
          if (!mounted || gen != _loadGen) return;
        }
      }
    } catch (error) {
      if (mounted && gen == _loadGen) {
        appLog('home-lx: 榜单加载最终失败（$_platform/${_chart.id}）: $error');
        setState(() => _error = _tracks.isEmpty ? friendlyError(error) : null);
      }
    } finally {
      if (mounted && gen == _loadGen) setState(() => _loading = false);
    }
  }

  /// 音源切换面板入口（见 showHomeSourceSheet）。
  Future<void> _showSourceSheet() async {
    await showHomeSourceSheet(context);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final catalog = lxCatalogFor(_platform);
    // 音源 = 激活脚本（对齐 lx-music）；未选具体脚本时以曲库平台为题
    final activeScript = settings.lxScript.isEmpty
        ? null
        : LxRuntime.instance.scriptById(settings.lxScript);
    return Scaffold(
      appBar: AppBar(
        title: Text(activeScript?.name ?? lxPlatformName(_platform)),
        actions: [
          IconButton(
            tooltip: '切换音源',
            icon: const Icon(Icons.swap_vert_circle_outlined),
            onPressed: _showSourceSheet,
          ),
          IconButton(
            tooltip: '播放全部',
            icon: const Icon(Icons.play_circle),
            onPressed: _tracks.isEmpty
                ? null
                : () => player.playQueue(_tracks, 0),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            // 平台榜单卡条：目录随音源换装（kg/wy/tx 真榜单，kw 关键词流）
            SliverToBoxAdapter(
              child: SizedBox(
                height: 92,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  itemCount: catalog.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final scene = catalog[index];
                    final selected = scene.id == _chart.id;
                    return GestureDetector(
                      onTap: () async {
                        if (!selected) {
                          setState(() => _chart = scene);
                          await _reload();
                        }
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 132,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: selected
                                ? [
                                    scheme.primary.withValues(alpha: 0.95),
                                    scheme.tertiary.withValues(alpha: 0.8),
                                  ]
                                : [
                                    scheme.surfaceContainerHigh,
                                    scheme.surfaceContainerHigh,
                                  ],
                          ),
                          border: selected
                              ? null
                              : Border.all(
                                  color: scheme.outlineVariant, width: 1),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(scene.emoji,
                                style: const TextStyle(fontSize: 20)),
                            const SizedBox(height: 6),
                            Text(
                              scene.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: selected
                                    ? Colors.white
                                    : scheme.onSurface,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            // 榜单「查看全部」→ 平台曲目页（可继续翻页）
            if (_tracks.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                  child: Row(
                    children: [
                      Text(
                        '${lxPlatformName(_platform)} · ${_chart.title}',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => PlatformTracksPage(
                              platform: _platform,
                              chartId: _chart.id,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.chevron_right, size: 18),
                        label: const Text('更多'),
                      ),
                    ],
                  ),
                ),
              ),
            if (_error != null && _tracks.isEmpty)
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
                        onPressed: _reload,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              )
            else if (_loading && _tracks.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: SkeletonBody(count: 9),
              )
            else if (_tracks.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('该分类暂无内容')),
              )
            else
              SliverList.builder(
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
          ],
        ),
      ),
    );
  }
}
