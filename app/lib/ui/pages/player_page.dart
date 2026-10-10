import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/api.dart';
import '../../core/appearance.dart';
import '../../core/lx_catalog.dart';
import '../../core/lx_runtime.dart';
import '../../core/logging.dart';
import '../../core/lyrics.dart';
import '../../core/models.dart';
import '../../core/palette.dart';
import '../../core/player.dart';
import '../../core/store.dart';
import '../../main.dart';
import '../nav.dart';
import '../widgets/cover.dart';
import '../widgets/lyrics_style_sheet.dart';
import 'artist_page.dart';

/// 正在播放页（常驻 Tab，替代原独立搜索 Tab + 迷你条动线）：
/// 封面 / 进度 / 控制 / 歌词（自动跟随滚动）/ 队列。
///
/// 个性化（借鉴 Beans-Music）：
/// - 壁纸背景：封面取色渐变（默认）/ 自选色渐变 / 相册照片（模糊度可调）
/// - 封面点按：切换「大字歌词」聚焦视图
/// - 进度条：经典 / 流光 / 辉光 / 极光 / 波浪
/// - 快捷动作行：长按拖动排序（appearance 持久化）
/// - 歌词样式 DIY（字号/行距/配色/发光/3D 倾斜）。
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  List<LyricLine> _lyrics = [];
  bool _lyricsLoading = false;
  String? _lyricsTrackId;
  Map<int, String> _translations = const {};

  /// 热门评论（随歌词请求带回；SEO 分享页内嵌，只读）。
  /// 展示数量一律用列表长度：SEO 回包的 `commentCount` 是全站总评论数，
  /// 与实际内嵌的热门评论条数对不上（2026-10-09 用户反馈）。
  List<TrackComment> _comments = const [];

  /// 当前封面主色（沉浸式背景；null = 未取到，用主题色）。
  Color? _dominant;
  String? _dominantTrackId;

  /// 封面点按切换的「大字歌词」聚焦视图（封面缩小退场、歌词放大）。
  bool _lyricsFocus = false;

  /// 相册壁纸文件（选中且存在才非 null）。
  File? _wallpaperFile;

  @override
  void initState() {
    super.initState();
    player.addListener(_onPlayerChanged);
    appearance.addListener(_onAppearanceChanged);
    _onPlayerChanged();
    _resolveWallpaperFile();
  }

  @override
  void dispose() {
    appearance.removeListener(_onAppearanceChanged);
    player.removeListener(_onPlayerChanged);
    super.dispose();
  }

  void _onAppearanceChanged() {
    if (appearance.wallpaperIsPhoto) {
      _resolveWallpaperFile();
    } else if (_wallpaperFile != null) {
      setState(() => _wallpaperFile = null);
    }
  }

  Future<void> _resolveWallpaperFile() async {
    final file = appearance.wallpaperIsPhoto ? await wallpaperFile() : null;
    final exists = file != null && file.existsSync();
    if (!mounted) return;
    setState(() => _wallpaperFile = exists ? file : null);
  }

  /// 切歌时加载歌词（监听驱动，避免在 build 里触发 setState）。
  void _onPlayerChanged() {
    final track = player.currentTrack;
    if (track == null) {
      appearance.updateDominant(null);
      if (_lyricsTrackId != null) {
        setState(() {
          _lyrics = [];
          _translations = const {};
          _lyricsTrackId = null;
          _dominant = null;
          _dominantTrackId = null;
          _comments = const [];
        });
      }
      return;
    }
    if (_lyricsTrackId == track.id) return;
    _loadLyrics(track);
    _loadDominant(track);
  }

  /// 封面主色：等封面缓存就绪后取色（失败静默回落主题色）。
  Future<void> _loadDominant(Track track) async {
    if (_dominantTrackId == track.id) return;
    setState(() => _dominantTrackId = track.id);
    try {
      final file = await resolveCoverFile(track.cover);
      final color = await Palette.dominant(track.cover, file);
      if (!mounted || player.currentTrack?.id != track.id) return;
      setState(() => _dominant = color);
      // 全局主题「跟随封面取色」共用这一份取色结果
      appearance.updateDominant(color);
    } catch (error) {
      appLog('player: 取色失败（忽略）: $error');
    }
  }

  Future<void> _loadLyrics(Track track) async {
    setState(() {
      _lyricsLoading = true;
      _lyricsTrackId = track.id;
    });
    try {
      // 平台曲目（kw/wy/kg/tx）走平台免签歌词；汽水曲目走账号接口
      final lyric = track.platform.isEmpty
          ? await Api.lyricsWithTranslation(track.id)
          : await Api.platformLyrics(track.platform, track.songmid, track.id);
      final parsed = parseLrc(lyric.lrc);
      // 翻译（Rust 侧已按 cn 优先排序，取第一种语言对齐到主歌词行）
      var aligned = const <int, String>{};
      if (lyric.translations.isNotEmpty) {
        aligned = alignTranslations(parsed, lyric.translations.values.first);
      }
      if (mounted) {
        setState(() {
          _lyrics = parsed;
          _translations = aligned;
          _comments = lyric.comments;
        });
      }
      if (lyric.lrc.trim().isNotEmpty && parsed.isEmpty) {
        appLog('lyrics: 「${track.title}」拿到 ${lyric.lrc.length} 字符但解析为 0 行（格式不识别）');
      }
    } catch (error) {
      appLog('lyrics: 「${track.title}」加载失败: $error');
      if (mounted) {
        setState(() {
          _lyrics = [];
          _translations = const {};
        });
      }
    } finally {
      if (mounted) setState(() => _lyricsLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 沉浸式：封面主色派生整套暗色 ColorScheme；背景按个性化设置
    // （封面渐变 / 自选色渐变 / 相册壁纸）铺满。
    final base = Theme.of(context);
    final accent = _dominant ?? base.colorScheme.primary;
    final immersive = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    );
    final scaffold = Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(player.radioActive
            ? '电台 · ${player.radio!.station.title}'
            : '正在播放'),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([player, player.preparingTrack, appearance]),
        builder: (context, _) {
          final track = player.currentTrack;
          if (track == null) {
            // 空态引导（本页现在是常驻 Tab，首启/清空队列后会看到）
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.music_note_outlined,
                      size: 52, color: immersive.outline),
                  const SizedBox(height: 12),
                  const Text('还没有正在播放的曲目'),
                  const SizedBox(height: 10),
                  FilledButton.tonal(
                    onPressed: () => homeTabIndex.value = kDiscoverTabIndex,
                    child: const Text('去发现找歌'),
                  ),
                ],
              ),
            );
          }
          final preparing = player.preparingTrack.value != null;
          return Column(
            children: [
              Expanded(
                flex: _lyricsFocus ? 2 : 5,
                child: _CoverSection(
                  track: track,
                  preparing: preparing,
                  compact: _lyricsFocus,
                  onSwiped: (forward) => forward
                      ? player.skipToNext()
                      : player.skipToPrevious(),
                  onVerticalSwiped: (up) => up
                      ? player.skipToNext()
                      : player.skipToPrevious(),
                  onCoverTap: () => setState(() => _lyricsFocus = !_lyricsFocus),
                ),
              ),
              // 音质/电台/评论徽标行：播放流状态 + 内容入口，水平排列
              // 紧贴进度条（点击音质切档、评论看热门评论）。
              if (player.currentQuality.isNotEmpty ||
                  player.radioActive ||
                  (!player.radioActive && _comments.isNotEmpty))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (player.currentQuality.isNotEmpty)
                        _QualityChip(label: player.currentQuality),
                      if (player.radioActive)
                        _RadioChip(label: player.radio!.station.title),
                      if (!player.radioActive && _comments.isNotEmpty)
                        _EntryChip(
                          icon: Icons.mode_comment_outlined,
                          label: _formatCount(_comments.length),
                          onPressed: () => _showComments(track),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _SeekBar(disabled: preparing),
              ),
              _Controls(onChanged: () => setState(() {})),
              _buildActionRow(context, immersive),
              const Divider(height: 20),
              Expanded(
                flex: _lyricsFocus ? 7 : 4,
                child: _LyricsView(
                  lyrics: _lyrics,
                  loading: _lyricsLoading,
                  translations: _translations,
                  showTranslation: settings.lyricTranslation,
                  scale: _lyricsFocus ? 1.3 : 1.0,
                ),
              ),
            ],
          );
        },
      ),
    );
    return Theme(
      data: base.copyWith(colorScheme: immersive),
      child: _PlayerBackground(
        accent: accent,
        wallpaperFile: _wallpaperFile,
        child: scaffold,
      ),
    );
  }

  /// 快捷动作行（长按拖动排序，appearance 持久化）：
  /// 队列 / 倍速 / 睡眠定时 / 翻译 / 分享 / 歌词样式。
  Widget _buildActionRow(BuildContext context, ColorScheme immersive) {
    final known = defaultPlayerActions.toSet();
    // 存储顺序优先，缺失的动作（后续版本新增）补到末尾
    final ordered = [
      ...appearance.playerActions.where(known.contains),
      ...defaultPlayerActions.where(
          (id) => !appearance.playerActions.contains(id)),
    ];
    final hasTranslation = _translations.isNotEmpty;
    Widget buttonFor(String id) {
      switch (id) {
        case 'queue':
          return IconButton(
            tooltip: '播放队列',
            icon: const Icon(Icons.queue_music),
            onPressed: () => _showQueue(context),
          );
        case 'speed':
          return PopupMenuButton<double>(
            tooltip: '播放速度',
            initialValue: settings.speed,
            onSelected: (value) async {
              settings.speed = value;
              await settings.save();
              await player.setSpeed(value);
              if (mounted) setState(() {});
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 0.5, child: Text('0.5x')),
              PopupMenuItem(value: 0.75, child: Text('0.75x')),
              PopupMenuItem(value: 1.0, child: Text('1.0x 常速')),
              PopupMenuItem(value: 1.25, child: Text('1.25x')),
              PopupMenuItem(value: 1.5, child: Text('1.5x')),
              PopupMenuItem(value: 2.0, child: Text('2.0x')),
            ],
            child: Container(
              height: 40,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                '${settings.speed}x',
                style: settings.speed == 1.0
                    ? null
                    : TextStyle(
                        color: immersive.primary,
                        fontWeight: FontWeight.w600,
                      ),
              ),
            ),
          );
        case 'sleep':
          return ListenableBuilder(
            listenable: player,
            builder: (context, _) {
              final active = player.sleepActive;
              return IconButton(
                tooltip: '睡眠定时器',
                icon: Icon(active ? Icons.bedtime : Icons.bedtime_outlined),
                color: active ? immersive.primary : null,
                onPressed: () => _showSleepMenu(context),
              );
            },
          );
        case 'translate':
          return IconButton(
            tooltip: settings.lyricTranslation ? '隐藏翻译' : '显示翻译',
            icon: Icon(Icons.translate),
            color: hasTranslation && settings.lyricTranslation
                ? immersive.primary
                : null,
            onPressed: hasTranslation
                ? () async {
                    settings.lyricTranslation = !settings.lyricTranslation;
                    await settings.save();
                    if (mounted) setState(() {});
                  }
                : null,
          );
        case 'share':
          return IconButton(
            tooltip: '分享',
            icon: const Icon(Icons.ios_share),
            onPressed: _shareCurrent,
          );
        case 'lyrics':
          return IconButton(
            tooltip: '歌词样式',
            icon: const Icon(Icons.format_size),
            onPressed: () => showLyricsStyleSheet(context),
          );
      }
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 48,
      child: ReorderableListView(
        scrollDirection: Axis.horizontal,
        buildDefaultDragHandles: false,
        onReorderItem: appearance.reorderPlayerActions,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        children: [
          for (var i = 0; i < ordered.length; i++)
            ReorderableDragStartListener(
              key: ValueKey('player-action-${ordered[i]}'),
              index: i,
              child: SizedBox(
                width: 56,
                child: Center(child: buttonFor(ordered[i])),
              ),
            ),
        ],
      ),
    );
  }

  /// 分享当前曲（文本进剪贴板；外链形态随服务端变化，用稳定的搜索兜底）。
  Future<void> _shareCurrent() async {
    final track = player.currentTrack;
    if (track == null) return;
    final station = player.radio?.station;
    final text = [
      '「${track.title}」- ${track.artist}',
      if (station != null) '来自电台「${station.title}」',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('已复制歌曲信息，去粘贴分享吧'),
        duration: Duration(seconds: 1),
      ));
  }

  void _showSleepMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('睡眠定时器',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              ListenableBuilder(
                listenable: player,
                builder: (context, _) {
                  final remaining = player.sleepRemainingSeconds;
                  if (remaining == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      remaining < 0 ? '当前这首播完即停' : '剩余约 ${(remaining / 60).ceil()} 分钟',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 4),
              for (final entry in const [
                (15, '15 分钟'),
                (30, '30 分钟'),
                (60, '60 分钟'),
                (0, '播完当前这首'),
                (-1, '取消定时'),
              ])
                ListTile(
                  dense: true,
                  leading: Icon(switch (entry.$1) {
                    0 => Icons.check_circle_outline,
                    -1 => Icons.cancel_outlined,
                    _ => Icons.timer_outlined,
                  }),
                  title: Text(entry.$2),
                  onTap: () {
                    player.setSleepTimer(
                        minutes: entry.$1 < 0 ? null : entry.$1);
                    Navigator.of(sheetContext).pop();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  /// 热门评论（SEO 分享页内嵌，只读；数据随歌词请求带回）。
  void _showComments(Track track) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.72,
      ),
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text('热门评论 · ${_comments.length} 条',
                  style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: _comments.length,
                itemBuilder: (context, index) {
                  final comment = _comments[index];
                  final meta = [
                    if (comment.ipLabel.isNotEmpty) comment.ipLabel,
                    if (comment.timeLabel.isNotEmpty) comment.timeLabel,
                  ].join(' · ');
                  return ListTile(
                    dense: true,
                    leading: ClipOval(
                      child: comment.avatar.isEmpty
                          ? Container(
                              width: 36,
                              height: 36,
                              color: scheme.surfaceContainerHighest,
                              child: Icon(Icons.person,
                                  size: 20, color: scheme.outline),
                            )
                          : CoverImage(url: comment.avatar, size: 36),
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            comment.nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (comment.featured) ...[
                          const SizedBox(width: 6),
                          Text('置顶',
                              style: TextStyle(
                                fontSize: 10,
                                color: scheme.primary,
                                fontWeight: FontWeight.w600,
                              )),
                        ],
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 2),
                        Text(comment.content, style: const TextStyle(fontSize: 14)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.favorite_border,
                                size: 13, color: scheme.outline),
                            const SizedBox(width: 3),
                            Text(_formatCount(comment.likes),
                                style: TextStyle(
                                    fontSize: 12, color: scheme.outline)),
                            if (comment.replies > 0) ...[
                              const SizedBox(width: 12),
                              Text('${comment.replies} 回复',
                                  style: TextStyle(
                                      fontSize: 12, color: scheme.outline)),
                            ],
                            const Spacer(),
                            if (meta.isNotEmpty)
                              Text(meta,
                                  style: TextStyle(
                                      fontSize: 11, color: scheme.outline)),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '展示热门评论（只读） · 完整评论区见官方 App',
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showQueue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      builder: (context) {
        return ListenableBuilder(
          listenable: player,
          builder: (context, _) {
            final queue = player.trackQueue;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
                  child: Row(
                    children: [
                      Text('播放队列 · ${queue.length} 首',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      TextButton(
                        onPressed: queue.isEmpty
                            ? null
                            : () async {
                                await player.clearQueue();
                                if (context.mounted) Navigator.of(context).pop();
                              },
                        child: const Text('清空'),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: queue.length,
                    itemBuilder: (context, index) {
                      final track = queue[index];
                      final current = index == player.index;
                      final tile = ListTile(
                        dense: true,
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: CoverImage(url: track.cover, size: 40),
                        ),
                        title: Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: current
                              ? TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                )
                              : null,
                        ),
                        subtitle: Text(track.artist, maxLines: 1),
                        trailing: current
                            ? const Icon(Icons.graphic_eq, size: 18)
                            : null,
                        onTap: () {
                          player.jumpToIndex(index);
                          Navigator.of(context).pop();
                        },
                      );
                      if (current) return tile;
                      return Dismissible(
                        key: ValueKey('queue-${track.id}-$index'),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) => player.removeAt(index),
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 24),
                          color: Theme.of(context).colorScheme.errorContainer,
                          child: Icon(
                            Icons.delete_outline,
                            color: Theme.of(context).colorScheme.onErrorContainer,
                          ),
                        ),
                        child: tile,
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// 播放页背景：按个性化设置切换封面取色渐变 / 自选色渐变 / 相册壁纸。
class _PlayerBackground extends StatelessWidget {
  const _PlayerBackground({
    required this.accent,
    required this.wallpaperFile,
    required this.child,
  });

  final Color accent;
  final File? wallpaperFile;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final preset = appearance.wallpaperPreset;
    final custom = appearance.wallpaperCustomColors;
    if (preset != null || custom != null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: preset?.colors ?? custom!,
          ),
        ),
        child: child,
      );
    }
    if (appearance.wallpaperIsPhoto && wallpaperFile != null) {
      final blur = appearance.wallpaperBlur;
      // 图片损坏 / 平台不支持解码时回落取色渐变（壁纸异常不能砸掉整个播放页）
      Widget photo() => Image.file(
            wallpaperFile!,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _accentGradient(accent),
          );
      return Stack(
        fit: StackFit.expand,
        children: [
          blur <= 0
              ? photo()
              : ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: blur,
                    sigmaY: blur,
                    tileMode: TileMode.decal,
                  ),
                  child: photo(),
                ),
          // 暗化蒙层：保证任意亮度的壁纸下白色文字可读
          ColoredBox(color: Colors.black.withValues(alpha: 0.38)),
          child,
        ],
      );
    }
    return _accentGradient(accent, child: child);
  }

  Widget _accentGradient(Color accent, {Widget? child}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.darken(0.18),
            accent.darken(0.62),
            accent.darken(0.78),
          ],
          stops: const [0, 0.55, 1],
        ),
      ),
      child: child,
    );
  }
}

/// 封面 + 曲目信息 + 错误重试。
/// 手势：横滑切歌（跟手位移 + 回弹）、上下滑切歌（抖音式）、
/// 点按切换「大字歌词」聚焦视图。
class _CoverSection extends StatefulWidget {
  const _CoverSection({
    required this.track,
    required this.preparing,
    required this.compact,
    required this.onSwiped,
    required this.onVerticalSwiped,
    required this.onCoverTap,
  });

  final Track track;
  final bool preparing;

  /// 大字歌词聚焦态：封面缩小、信息精简。
  final bool compact;

  /// 横滑结束回调：true=下一首，false=上一首。
  final ValueChanged<bool> onSwiped;

  /// 上下滑结束回调：true=上滑（下一首），false=下滑（上一首）。
  final ValueChanged<bool> onVerticalSwiped;

  /// 封面点按（切换歌词聚焦视图）。
  final VoidCallback onCoverTap;

  @override
  State<_CoverSection> createState() => _CoverSectionState();
}

class _CoverSectionState extends State<_CoverSection> {
  double _dragDx = 0;
  double _dragDy = 0;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final size = widget.compact
          ? 76.0
          : math
              .min(constraints.maxWidth - 24, constraints.maxHeight - 104)
              .clamp(140.0, 300.0);
      final cover = ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            CoverImage(url: track.cover, size: size),
            if (widget.preparing)
              Positioned.fill(
                child: Container(
                  color: Colors.black38,
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 10),
                        Text('下载 / 解密中…',
                            style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GestureDetector(
            onHorizontalDragUpdate: (details) =>
                setState(() => _dragDx += details.delta.dx),
            onHorizontalDragEnd: (details) {
              final dx = _dragDx;
              final velocity = details.primaryVelocity ?? 0;
              setState(() => _dragDx = 0);
              // 位移超过 1/4 封面宽或快速甩动即切歌
              if (dx < -size / 4 || velocity < -600) {
                widget.onSwiped(true);
              } else if (dx > size / 4 || velocity > 600) {
                widget.onSwiped(false);
              }
            },
            // 抖音式上下滑切歌：上滑下一首、下滑上一首
            onVerticalDragUpdate: (details) =>
                setState(() => _dragDy += details.delta.dy),
            onVerticalDragEnd: (details) {
              final dy = _dragDy;
              final velocity = details.primaryVelocity ?? 0;
              setState(() => _dragDy = 0);
              if (dy < -size / 4 || velocity < -600) {
                widget.onVerticalSwiped(true);
              } else if (dy > size / 4 || velocity > 600) {
                widget.onVerticalSwiped(false);
              }
            },
            onTap: widget.onCoverTap,
            child: Transform.translate(
              offset: Offset(_dragDx * 0.6, _dragDy * 0.25),
              child: cover,
            ),
          ),
          SizedBox(height: widget.compact ? 8 : 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              track.title,
              style: widget.compact
                  ? Theme.of(context).textTheme.titleMedium
                  : Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
              maxLines: widget.compact ? 1 : 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 4),
          // 歌手名可点 → 艺人页（有 artistId 才给入口）
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: track.artistId.isEmpty || widget.compact
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ArtistPage(
                          artistId: track.artistId,
                          name: track.artist,
                          avatar: '',
                        ),
                      ),
                    ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                [
                  if (track.artist.isNotEmpty) track.artist,
                  if (track.album.isNotEmpty && !widget.compact) track.album,
                ].join(' · '),
                textAlign: TextAlign.center,
                maxLines: widget.compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: widget.compact
                    ? TextStyle(color: scheme.outline, fontSize: 12)
                    : TextStyle(color: scheme.outline),
              ),
            ),
          ),
          if (!widget.compact) ...[
            if (player.currentQuality.contains('试听'))
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: Text(
                  '当前为试听片段：App 会话受服务端限制，扫码登录后可播整曲',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.outline, fontSize: 11),
                ),
              ),
            if (player.lastError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Column(
                  children: [
                    Text(
                      player.lastError!,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.error, fontSize: 12),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重试本曲'),
                      onPressed: () => player.jumpToIndex(player.index),
                    ),
                  ],
                ),
              ),
          ],
        ],
      );
    });
  }
}

/// 电台徽标：播放页里标识「来自电台」。
class _RadioChip extends StatelessWidget {
  const _RadioChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.radio, size: 15, color: scheme.primary),
          const SizedBox(width: 4),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.outline)),
        ],
      ),
    );
  }
}

/// 当前音质徽标：点击弹出音质档位菜单（选中后保持进度重载当前曲）。
class _QualityChip extends StatelessWidget {
  const _QualityChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _showQualitySheet(context),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        // 加大热区与字号（此前高度仅约 22px，不好点）
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq, size: 15, color: scheme.primary),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(fontSize: 12.5, color: scheme.outline)),
            Icon(Icons.arrow_drop_down, size: 18, color: scheme.outline),
          ],
        ),
      ),
    );
  }

  /// 字节数 → 用户可读大小（30M / 35.6M / 480KB）。
  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}G';
    }
    if (bytes >= 1024 * 1024) {
      final mb = bytes / (1024 * 1024);
      final text = mb.truncateToDouble() == mb
          ? mb.toInt().toString()
          : mb.toStringAsFixed(1);
      return '${text}M';
    }
    return '${(bytes / 1024).round()}KB';
  }

  void _showQualitySheet(BuildContext context) {
    // LX 模式档位随就绪脚本动态变化：面板打开前刷新一次脚本状态
    // （与首页音源面板同模式：先刷新再展示，选项才是新鲜的）。
    if (settings.sourceMode == 'lx') {
      unawaited(() async {
        await LxRuntime.instance.ensureStarted();
        await LxRuntime.instance.refreshStatus();
        if (!context.mounted) return;
        _openQualitySheet(context);
      }());
    } else {
      _openQualitySheet(context);
    }
  }

  void _openQualitySheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        // 音源展示以实际为准：优先当前曲的实际取流来源（如
        // 「其他音源-独家LX」），无播放记录时回落设置里的音源模式。
        final origin = player.currentSourceLabel.isNotEmpty
            ? player.currentSourceLabel
            : settings.sourceName;
        final qualityPart =
            player.currentQuality.isEmpty ? '' : '-${player.currentQuality}';
        final sizePart = player.currentSizeBytes == null
            ? ''
            : '（${_formatBytes(player.currentSizeBytes!)}）';
        // 档位选项按音源动态出：汽水 = 账号五档；其他音源 = 实际音源
        // （正在播的平台曲目优先，否则设置的平台）就绪脚本声明
        // qualitys 的并集（不写死，随脚本/平台变化）。
        final isLx = settings.sourceMode == 'lx';
        final playingPlatform = player.currentTrack?.platform;
        final platform = isLx
            ? (const {'kw', 'wy', 'kg', 'tx'}.contains(playingPlatform)
                ? playingPlatform!
                : settings.lxPlatform)
            : '';
        final options = <(String, String)>[
          if (isLx)
            for (final quality
                in LxRuntime.instance.availableQualities(platform))
              (quality, lxQualityLabels[quality] ?? quality)
          else
            for (final entry in qualityOptions.entries)
              (entry.key, entry.value),
        ];
        final selectedKey = isLx ? settings.lxQuality : settings.quality;
        IconData iconOf(String key) => isLx
            ? switch (key) {
                'flac24bit' => Icons.graphic_eq_outlined,
                'flac' => Icons.workspace_premium_outlined,
                '320k' => Icons.high_quality_outlined,
                '128k' => Icons.music_note_outlined,
                _ => Icons.auto_awesome_outlined,
              }
            : switch (key) {
                'spatial' => Icons.surround_sound_outlined,
                'hires' => Icons.graphic_eq_outlined,
                'lossless' => Icons.workspace_premium_outlined,
                'highest' => Icons.high_quality_outlined,
                'medium' => Icons.music_note_outlined,
                _ => Icons.auto_awesome_outlined,
              };
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text('音质',
                    style: Theme.of(sheetContext).textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  '当前音源：$origin$qualityPart$sizePart · 切换档位后重新下载当前曲目',
                  style: TextStyle(color: scheme.outline, fontSize: 12),
                ),
              ),
              for (final (key, label) in options)
                ListTile(
                  dense: true,
                  leading: Icon(
                    iconOf(key),
                    color: selectedKey == key ? scheme.primary : null,
                  ),
                  title: Text(label),
                  trailing: selectedKey == key
                      ? Icon(Icons.check, color: scheme.primary)
                      : null,
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    if (selectedKey == key) return;
                    if (isLx) {
                      // lxQuality 是 Dart 侧解析链偏好，不进 FFI 配置
                      settings.lxQuality = key;
                      await settings.save();
                    } else {
                      settings.quality = key;
                      await settings.save();
                      final cacheDir = await Settings.resolveCacheDir();
                      await Api.configure(settings.toFfiConfig(cacheDir));
                    }
                    appLog('quality: 档位 → '
                        '"${key.isEmpty ? '自动' : key}"，保持进度重载当前曲');
                    await player.reloadCurrent();
                  },
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  isLx
                      ? '选项 = ${lxPlatformName(platform)}平台就绪脚本'
                          '实际支持的音质并集；所选档位不可用时自动逐级回落。'
                      : '自动 = 按账号权益选最优；无损需账号 VIP 权益，无权限时自动回退可用档位。'
                          '酷我/网易云曲目的实际音质取决于取流脚本。',
                  style: TextStyle(color: scheme.outline, fontSize: 11),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 进度条（拖动跟手 + seek 后钉住目标）+ ±15 秒快退/快进。
///
/// positionStream 约每 200ms 推一次播放进度；网络流 seek 后底层要等
/// 新位置缓冲完成才会把进度上报到目标值，期间一直推旧进度——若直接
/// 把流值灌进滑条，拖动中和松手后滑块都会被旧进度弹回，等缓冲完
/// 才跳到位（2026-10-09 用户反馈）。对策：
/// - 拖动中显示手指位置，忽略流值；
/// - 松手才 seek 一次（拖动中反复 seek 会让网络流反复重建缓冲区，
///   且每次都会触发会话保存）；
/// - seek 落地前把显示钉在目标位置，流值追近目标（差 < 1.5s）后
///   恢复跟随，避免松手后弹回。
///
/// 样式（个性化）：经典 Material 滑条 / 流光 / 辉光 / 极光 / 波浪。
class _SeekBar extends StatefulWidget {
  const _SeekBar({this.disabled = false});

  /// 准备中（音频源已停）：禁用拖动，位置归零显示。
  final bool disabled;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar>
    with SingleTickerProviderStateMixin {
  bool _dragging = false;
  double _dragValue = 0;

  /// seek 钉住值（毫秒）及所属曲目：换歌 / 回恢复态即作废，
  /// 防止旧 seek 把新曲进度钉在错误位置。
  double? _pinnedMs;
  String? _pinnedTrackId;

  /// 自绘样式的循环动画（流光滑过 / 极光流转 / 波浪推进）。
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void initState() {
    super.initState();
    if (appearance.progressBar != ProgressBarStyle.classic &&
        player.audioPlayer.playing) {
      _anim.repeat();
    }
    _stateSub = player.audioPlayer.playerStateStream.listen((state) {
      if (appearance.progressBar == ProgressBarStyle.classic) return;
      if (state.playing) {
        if (!_anim.isAnimating) _anim.repeat();
      } else {
        _anim.stop();
      }
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _anim.dispose();
    super.dispose();
  }

  int _durationMs() =>
      player.audioPlayer.duration?.inMilliseconds ??
      (player.currentTrack?.durationSeconds ?? 0) * 1000;

  /// ±15 秒跳转（与拖动共用「钉住」机制防回弹）。
  void _jumpBy(int deltaMs) {
    final max = _durationMs().toDouble();
    if (max <= 0 || player.restoring || widget.disabled) return;
    final now = player.audioPlayer.position.inMilliseconds.toDouble();
    final target = (now + deltaMs).clamp(0, max.toInt()).toDouble();
    setState(() {
      _pinnedMs = target;
      _pinnedTrackId = player.currentTrack?.id;
    });
    player
        .seek(Duration(milliseconds: target.toInt()))
        .catchError((Object error) {
      appLog('player: seek 失败（解除进度钉住）: $error');
      if (mounted) setState(() => _pinnedMs = null);
    });
  }

  void _commitSeek(double endMs) {
    setState(() {
      _dragging = false;
      _pinnedMs = endMs;
      _pinnedTrackId = player.currentTrack?.id;
    });
    player
        .seek(Duration(milliseconds: endMs.toInt()))
        .catchError((Object error) {
      appLog('player: seek 失败（解除进度钉住）: $error');
      if (mounted) setState(() => _pinnedMs = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.audioPlayer.positionStream,
      builder: (context, snapshot) {
        // 恢复态：音频未加载，显示上次进度；拖动会在加载后失效，先禁用
        final restoring = player.restoring;
        if (restoring) _pinnedMs = null;
        final position = restoring
            ? Duration(milliseconds: player.restoredPositionMs ?? 0)
            : snapshot.data ?? Duration.zero;
        final duration = player.audioPlayer.duration ??
            Duration(seconds: player.currentTrack?.durationSeconds ?? 0);
        final max = duration.inMilliseconds.toDouble();
        // 拖动中途被禁用（如切歌进入 preparing）时手势会静默终止、
        // 不回调 onChangeEnd，这里兜底复位拖动态，避免滑块冻结在旧位置。
        if (restoring || widget.disabled || max <= 0) _dragging = false;
        var value = max <= 0
            ? 0.0
            : position.inMilliseconds.toDouble().clamp(0.0, max).toDouble();
        if (!restoring && max > 0) {
          final trackId = player.currentTrack?.id;
          if (_pinnedTrackId != trackId) _pinnedMs = null;
          final pinned = _pinnedMs;
          if (pinned != null) {
            // 流值已追近目标（seek 已落地并继续播进）→ 解除钉住
            if ((value - pinned).abs() < 1500) {
              _pinnedMs = null;
            } else {
              value = pinned.clamp(0.0, max);
            }
          }
          if (_dragging) value = _dragValue.clamp(0.0, max);
        }
        final enabled = max > 0 && !restoring && !widget.disabled;
        final scheme = Theme.of(context).colorScheme;
        final classic = appearance.progressBar == ProgressBarStyle.classic;
        return Row(
          children: [
            IconButton(
              tooltip: '后退 15 秒',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.fast_rewind),
              onPressed: enabled ? () => _jumpBy(-15000) : null,
            ),
            Expanded(
              child: Column(
                children: [
                  if (classic)
                    Slider(
                      value: value,
                      max: max <= 0 ? 1.0 : max,
                      // 准备中音频处于 idle，直接 seek 底层会抛错——经 PlayerController
                      // 的守卫入口走（准备中忽略）。
                      onChangeStart: enabled
                          ? (start) => setState(() {
                                _dragging = true;
                                _dragValue = start;
                                _pinnedMs = null;
                              })
                          : null,
                      onChanged: enabled
                          ? (next) => setState(() => _dragValue = next)
                          : null,
                      onChangeEnd: enabled ? _commitSeek : null,
                    )
                  else
                    _FancyBar(
                      value: value,
                      max: max,
                      enabled: enabled,
                      animation: _anim,
                      primary: scheme.primary,
                      onDragStart: (start) => setState(() {
                        _dragging = true;
                        _dragValue = start;
                        _pinnedMs = null;
                      }),
                      onDragUpdate: (next) => setState(() => _dragValue = next),
                      onCommit: _commitSeek,
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // 时间标签跟随滑块显示值（拖动 / 钉住时同样生效）
                        Text(_label(Duration(milliseconds: value.toInt()))),
                        Text(_label(duration)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '前进 15 秒',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.fast_forward),
              onPressed: enabled ? () => _jumpBy(15000) : null,
            ),
          ],
        );
      },
    );
  }

  String _label(Duration duration) {
    final seconds = duration.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

/// 自绘进度条（流光/辉光/极光/波浪）：拖动/点按 seek 与 Slider 同语义。
class _FancyBar extends StatelessWidget {
  const _FancyBar({
    required this.value,
    required this.max,
    required this.enabled,
    required this.animation,
    required this.primary,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onCommit,
  });

  final double value;
  final double max;
  final bool enabled;
  final Animation<double> animation;
  final Color primary;
  final ValueChanged<double>? onDragStart;
  final ValueChanged<double>? onDragUpdate;
  final ValueChanged<double>? onCommit;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      double fractionFor(double localDx) =>
          width <= 0 ? 0 : (localDx.clamp(0.0, width) / width) * max;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: enabled
            ? (details) => onDragStart?.call(fractionFor(details.localPosition.dx))
            : null,
        onHorizontalDragUpdate: enabled
            ? (details) =>
                onDragUpdate?.call(fractionFor(details.localPosition.dx))
            : null,
        // 拖动结束时 value 即父级记录的最后一次拖动值（拖动中父级把
        // value 钉在 _dragValue），点按则直接换算落点。
        onHorizontalDragEnd: enabled ? (_) => onCommit?.call(value) : null,
        onTapUp: enabled
            ? (details) => onCommit?.call(fractionFor(details.localPosition.dx))
            : null,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) => CustomPaint(
            size: const Size(double.infinity, 36),
            painter: _ProgressBarPainter(
              style: appearance.progressBar,
              fraction:
                  max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0).toDouble(),
              primary: primary,
              phase: animation.value,
              dimmed: !enabled,
            ),
          ),
        ),
      );
    });
  }
}

/// 四款自绘进度条的统一画笔。
class _ProgressBarPainter extends CustomPainter {
  _ProgressBarPainter({
    required this.style,
    required this.fraction,
    required this.primary,
    required this.phase,
    required this.dimmed,
  });

  final ProgressBarStyle style;
  final double fraction;
  final Color primary;
  final double phase;
  final bool dimmed;

  static const _barHeight = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final cy = size.height / 2;
    final trackPaint = Paint()
      ..color = Colors.white.withValues(alpha: dimmed ? 0.12 : 0.22);
    final trackRect = Rect.fromCenter(
      center: Offset(w / 2, cy),
      width: w,
      height: _barHeight,
    );
    final track = RRect.fromRectAndRadius(trackRect, const Radius.circular(3));
    final fillWidth = (w * fraction).clamp(0.0, w);

    switch (style) {
      case ProgressBarStyle.classic:
        break; // 不会用到（classic 走 Slider）
      case ProgressBarStyle.streamer:
        canvas.drawRRect(track, trackPaint);
        if (fillWidth > 0) {
          final fill = Rect.fromLTWH(0, cy - _barHeight / 2, fillWidth,
              _barHeight);
          // 底色填充
          canvas.drawRect(
            fill,
            Paint()
              ..shader = LinearGradient(
                colors: [primary, primary.lighten(0.25)],
              ).createShader(fill),
          );
          // 流光带：随 phase 从左往右扫过已播放部分
          final p = phase.clamp(0.0, 1.0) * (fillWidth + 60) - 30;
          final startX = p.clamp(0.0, fillWidth);
          final bandWidth = (fillWidth - startX).clamp(0.0, 30.0);
          if (bandWidth > 0 && !dimmed) {
            final band = Rect.fromLTWH(
                startX, cy - _barHeight / 2, bandWidth, _barHeight);
            canvas.drawRect(
              band,
              Paint()
                ..shader = LinearGradient(
                  colors: [
                    Colors.white.withValues(alpha: 0),
                    Colors.white.withValues(alpha: 0.65),
                  ],
                ).createShader(band),
            );
          }
        }
        _drawThumb(canvas, w * fraction, cy);
      case ProgressBarStyle.glow:
        canvas.drawRRect(track, trackPaint);
        if (fillWidth > 0) {
          final fill = RRect.fromRectAndRadius(
            Rect.fromLTWH(0, cy - _barHeight / 2, fillWidth, _barHeight),
            const Radius.circular(3),
          );
          if (!dimmed) {
            // 柔和光晕（两圈不同强度）
            canvas.drawRRect(
              fill,
              Paint()
                ..color = primary.withValues(alpha: 0.35)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
            );
            canvas.drawRRect(
              fill,
              Paint()
                ..color = primary.withValues(alpha: 0.5)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
            );
          }
          canvas.drawRRect(fill, Paint()..color = primary.lighten(0.1));
        }
        _drawThumb(canvas, w * fraction, cy, glow: true);
      case ProgressBarStyle.aurora:
        final aurora = _auroraColors();
        canvas.drawRRect(
          track,
          Paint()
            ..shader = LinearGradient(
              colors: aurora,
            ).createShader(trackRect),
        );
        if (dimmed) break;
        if (fillWidth > 0) {
          // 已播放部分：不透明极光；剩余部分留在半透明轨道里
          canvas.save();
          canvas.clipRect(Rect.fromLTWH(0, 0, fillWidth, size.height));
          canvas.drawRRect(
            track,
            Paint()
              ..shader = LinearGradient(colors: aurora).createShader(trackRect),
          );
          canvas.restore();
        }
        _drawThumb(canvas, w * fraction, cy);
      case ProgressBarStyle.wave:
        // 暗轨道
        canvas.drawRRect(track, trackPaint);
        if (fillWidth <= 0 || dimmed) {
          _drawThumb(canvas, 0, cy);
          break;
        }
        // 主波浪线（已播放部分），相位随 phase 流动
        canvas.drawPath(
          _wavePath(fillWidth, cy, amplitude: 4.5, wavelength: 34,
              phaseOffset: phase * 2 * math.pi),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round
            ..color = primary,
        );
        // 次级淡波（错相，营造层次）
        canvas.drawPath(
          _wavePath(fillWidth, cy, amplitude: 2.5, wavelength: 26,
              phaseOffset: -phase * 2 * math.pi + math.pi / 2),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = primary.withValues(alpha: 0.4),
        );
        _drawThumb(canvas, w * fraction, cy);
    }
  }

  Path _wavePath(double width, double cy,
      {required double amplitude, required double wavelength,
      required double phaseOffset}) {
    final path = Path()..moveTo(0, cy);
    if (width <= 0) return path;
    for (var x = 0.0; x <= width; x += 2) {
      final y = cy +
          amplitude *
              math.sin(2 * math.pi * x / wavelength + phaseOffset) *
              (1 - 0.2 * x / width);
      path.lineTo(x, y);
    }
    return path;
  }

  /// 极光渐变色：主题色与几个相邻色相随 phase 流转。
  List<Color> _auroraColors() {
    Color shift(Color color, double degrees) => HSVColor.fromColor(color)
        .withHue((HSVColor.fromColor(color).hue + degrees) % 360)
        .toColor();
    final rotation = phase * 120;
    return [
      shift(primary, rotation),
      shift(primary, rotation + 40),
      shift(primary, rotation + 80),
      shift(primary, rotation + 160),
      shift(primary, rotation + 240),
    ];
  }

  void _drawThumb(Canvas canvas, double x, double cy, {bool glow = false}) {
    if (glow && !dimmed) {
      canvas.drawCircle(
        Offset(x, cy),
        11,
        Paint()
          ..color = primary.withValues(alpha: 0.5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }
    canvas.drawCircle(
      Offset(x, cy),
      6.5,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_ProgressBarPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.phase != phase ||
      oldDelegate.style != style ||
      oldDelegate.primary != primary ||
      oldDelegate.dimmed != dimmed;
}

class _Controls extends StatelessWidget {
  const _Controls({required this.onChanged});

  final VoidCallback onChanged;

  IconData _modeIcon(PlayMode mode) => switch (mode) {
        PlayMode.sequence => Icons.repeat,
        PlayMode.repeatOne => Icons.repeat_one,
        PlayMode.shuffle => Icons.shuffle,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // 电台模式：播放模式位换成「不喜欢」（语义更贴官方 FM）；
        // 不喜欢 = 本会话拉黑 + 立刻换下一首。
        player.radioActive
            ? IconButton(
                tooltip: '不喜欢，换一首',
                icon: const Icon(Icons.thumb_down_alt_outlined),
                color: scheme.primary,
                onPressed: () async {
                  await player.radioDislikeCurrent();
                  onChanged();
                },
              )
            : IconButton(
                tooltip: player.playMode.label,
                icon: Icon(_modeIcon(player.playMode)),
                color: scheme.primary,
                onPressed: () async {
                  await player.cyclePlayMode();
                  onChanged();
                },
              ),
        IconButton(
          iconSize: 34,
          icon: const Icon(Icons.skip_previous),
          onPressed: player.skipToPrevious,
        ),
        StreamBuilder<PlayerState>(
          stream: player.audioPlayer.playerStateStream,
          builder: (context, snapshot) {
            final playing = snapshot.data?.playing ?? false;
            return IconButton(
              iconSize: 52,
              style: IconButton.styleFrom(
                backgroundColor: scheme.primaryContainer,
              ),
              icon: Icon(
                playing ? Icons.pause : Icons.play_arrow,
                size: 40,
              ),
              onPressed: player.toggle,
            );
          },
        ),
        IconButton(
          iconSize: 34,
          icon: const Icon(Icons.skip_next),
          onPressed: player.skipToNext,
        ),
        // 我喜欢：本地喜欢列表红心（与「我的 → 我喜欢的音乐」同一份数据；
        // 首页汽水形态的入口是抖音账号喜欢，另一份服务器数据）；无当前曲时禁用
        ListenableBuilder(
          listenable: likedStore,
          builder: (context, _) {
            final track = player.currentTrack;
            final liked =
                track != null && likedStore.isLiked(track.id);
            return IconButton(
              tooltip: liked ? '取消喜欢' : '我喜欢',
              icon: Icon(liked ? Icons.favorite : Icons.favorite_border),
              color: liked ? scheme.error : scheme.primary,
              onPressed: track == null
                  ? null
                  : () {
                      likedStore.toggle(track);
                      onChanged();
                    },
            );
          },
        ),
      ],
    );
  }
}

/// 歌词区：当前行高亮、点击行跳播、自动跟随滚动；
/// 用户手动滚动后暂停跟随，点「定位当前行」恢复。
/// 样式（字号/行距/配色/发光/3D 倾斜）由个性化外观驱动。
class _LyricsView extends StatefulWidget {
  const _LyricsView({
    required this.lyrics,
    required this.loading,
    this.translations = const {},
    this.showTranslation = true,
    this.scale = 1.0,
  });

  final List<LyricLine> lyrics;
  final bool loading;

  /// 行下标 → 译文（对齐后的翻译，空 Map = 无译文）。
  final Map<int, String> translations;

  /// 是否显示译文（播放页「译」开关，仅当有译文才有意义）。
  final bool showTranslation;

  /// 大字歌词聚焦视图的放大倍数。
  final double scale;

  @override
  State<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<_LyricsView> {
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _lineKeys = {};
  StreamSubscription<Duration>? _positionSub;
  int _active = -1;
  bool _following = true;
  double _sweep = 0; // 当前行卡拉OK扫色进度（0~1）
  double _lastNotifiedSweep = -1;

  @override
  void initState() {
    super.initState();
    _positionSub = player.audioPlayer.positionStream.listen((position) {
      final index =
          lyricIndexAt(widget.lyrics, position.inMilliseconds);
      if (index != _active) {
        setState(() {
          _active = index;
          _sweep = 0;
          _lastNotifiedSweep = -1;
        });
        if (_following) _revealActive();
      } else if (index >= 0) {
        // 逐字扫色：按字插值推进（限流避免每帧全量 setState）
        final next = lyricProgressAt(
            widget.lyrics, index, position.inMilliseconds);
        if ((next - _lastNotifiedSweep).abs() > 0.008) {
          setState(() {
            _sweep = next;
            _lastNotifiedSweep = next;
          });
        }
      }
    });
  }

  @override
  void didUpdateWidget(_LyricsView old) {
    super.didUpdateWidget(old);
    if (old.lyrics != widget.lyrics) {
      _lineKeys.clear();
      _active = -1;
      _following = true;
      // 换歌后回到顶部/定位当前行（下一帧 keys 就绪）
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealActive());
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// 歌词行间距（build 与节距估算共用一套参数）。
  double get _lineSpacing => 7.0 * appearance.lyricLineSpacing;

  /// 滚动到当前行。当前行在已建范围内时直接 ensureVisible；
  /// 被懒加载回收（滚远了）时按已建行实测节距估算偏移跳过去，
  /// 动画结束、目标行重建后再精确对齐——否则点「定位当前行」无效果。
  void _revealActive() {
    const alignment = 0.4;
    const duration = Duration(milliseconds: 260);
    if (!_scroll.hasClients) return;
    if (_active < 0) {
      // 前奏期（首行之前）：回到顶部
      _scroll.animateTo(0, duration: duration, curve: Curves.easeOutCubic);
      return;
    }
    final ctx = _lineKeys[_active]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: alignment,
        duration: duration,
        curve: Curves.easeOutCubic,
      );
      return;
    }
    final pitch = _measureLinePitch();
    if (pitch == null) return;
    final estimate = 24.0 /*列表顶部 padding*/ +
        (_active + alignment) * pitch -
        alignment * _scroll.position.viewportDimension;
    final target = math.max(
        0.0, math.min(estimate, _scroll.position.maxScrollExtent));
    _scroll
        .animateTo(target, duration: duration, curve: Curves.easeOutCubic)
        .then((_) {
      // 动画期间用户又接管了滚动就不再纠正
      if (!mounted || !_following) return;
      _alignActivePrecisely();
    });
  }

  /// ensureVisible 精确对齐当前行（估算跳转后的二次校正）。
  void _alignActivePrecisely() {
    final ctx = _lineKeys[_active]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.4,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  /// 量已上屏行的平均节距（行高 + 上下 spacing），
  /// 译文有无、字号、行距设置不同时自适应；当前行字号更大不参与。
  double? _measureLinePitch() {
    var sum = 0.0;
    var count = 0;
    for (final entry in _lineKeys.entries) {
      if (entry.key == _active) continue;
      final object = entry.value.currentContext?.findRenderObject();
      if (object is RenderBox && object.hasSize && object.size.height > 0) {
        sum += object.size.height;
        if (++count >= 10) break;
      }
    }
    if (count == 0) return null;
    return sum / count + 2 * _lineSpacing;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.loading && widget.lyrics.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.lyrics.isEmpty) {
      return Center(
        child: Text('暂无歌词', style: TextStyle(color: scheme.outline)),
      );
    }
    final app = appearance;
    final baseColor = app.lyricCustomColors ? app.lyricBaseColor : scheme.outline;
    final highlightColor =
        app.lyricCustomColors ? app.lyricHighlightColor : scheme.primary;
    final activeSize = app.lyricFontSize * widget.scale;
    final idleSize = (app.lyricFontSize - 2) * widget.scale;
    final translationSize = (app.lyricFontSize - 5) * widget.scale;
    final spacing = _lineSpacing;
    return Stack(
      children: [
        // 触摸歌词区即视为接管滚动，暂停自动跟随
        Listener(
          onPointerDown: (_) {
            if (_following) setState(() => _following = false);
          },
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 24),
            itemCount: widget.lyrics.length,
            itemBuilder: (context, index) {
              final key = _lineKeys.putIfAbsent(index, GlobalKey.new);
              final active = index == _active;
              Widget line = Column(
                children: [
                  if (active)
                    // 当前行：卡拉OK逐字扫色（底色行 + 裁切高亮行叠加）
                    _KaraokeLine(
                      text: widget.lyrics[index].text,
                      sweep: _sweep,
                      baseColor: baseColor,
                      highlightColor: highlightColor,
                      fontSize: activeSize,
                      glow: app.lyricGlow,
                    )
                  else
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOut,
                      style: TextStyle(
                        fontSize: idleSize,
                        color: baseColor,
                      ),
                      child: Text(
                        widget.lyrics[index].text,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  // 译文行（跟随主行高亮：当前行用主题色淡化，其余轮廓色）
                  if (widget.showTranslation &&
                      widget.translations[index] != null) ...[
                    const SizedBox(height: 2),
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOut,
                      style: TextStyle(
                        fontSize: translationSize,
                        color: active
                            ? highlightColor.withValues(alpha: 0.75)
                            : baseColor.withValues(alpha: 0.6),
                      ),
                      child: Text(
                        widget.translations[index]!,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ],
              );
              if (active && app.lyricTilt) {
                // 3D 倾斜：当前行轻微透视
                line = Transform(
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.002)
                    ..rotateX(-0.12),
                  alignment: Alignment.center,
                  child: line,
                );
              }
              return Padding(
                padding: EdgeInsets.symmetric(vertical: spacing),
                child: GestureDetector(
                  // 整行热区（此前只有文字本身可点）
                  behavior: HitTestBehavior.opaque,
                  onTap: () => player
                      .seek(Duration(
                          milliseconds: widget.lyrics[index].timeMs)),
                  child: Container(
                    key: key,
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 3),
                    child: line,
                  ),
                ),
              );
            },
          ),
        ),
        if (!_following)
          Positioned(
            right: 16,
            bottom: 12,
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.my_location, size: 18),
              label: const Text('定位当前行'),
              onPressed: () {
                setState(() => _following = true);
                _revealActive();
              },
            ),
          ),
      ],
    );
  }
}

/// 卡拉OK行：按播放进度从左到右扫色。
///
/// 水平线性渐变在扫色点做硬边（高亮色|底色），叠加 TweenAnimationBuilder
/// 把 positionStream 的离散更新（~200ms）补间成平滑推进；
/// 居中文本与逐字进度按字数插值（CJK 近似等宽，视觉足够准确）。
class _KaraokeLine extends StatelessWidget {
  const _KaraokeLine({
    required this.text,
    required this.sweep,
    required this.baseColor,
    required this.highlightColor,
    required this.fontSize,
    this.glow = false,
  });

  final String text;
  final double sweep;
  final Color baseColor;
  final Color highlightColor;
  final double fontSize;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: sweep),
      duration: const Duration(milliseconds: 220),
      curve: Curves.linear,
      builder: (context, value, child) {
        final stop = value.clamp(0.0, 1.0);
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [highlightColor, highlightColor, baseColor, baseColor],
            stops: [0, stop, stop, 1],
          ).createShader(bounds),
          child: child!,
        );
      },
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          // srcIn 混合下文字颜色被渐变整体替换，这里只需不透明；
          // 发光 = 双层柔影（shadow 像素同样被渐变着色，跟随扫色）
          color: const Color(0xFFFFFFFF),
          shadows: glow
              ? [
                  Shadow(color: highlightColor, blurRadius: 16),
                  Shadow(
                      color: highlightColor.withValues(alpha: 0.55),
                      blurRadius: 32),
                ]
              : null,
        ),
      ),
    );
  }
}

/// 计数简写：1.2万 / 9999。
String _formatCount(int count) {
  if (count >= 10000) {
    final value = count / 10000;
    return '${value >= 100 ? value.round() : value.toStringAsFixed(1)}万';
  }
  return count.toString();
}

/// 播放页内容入口 chip（热门评论）。
///
/// 沉浸式页背景是封面主色的深色渐变，主题色 chip（outline 灰字 +
/// surface 容器底）在该背景上对比度不足；固定用半透明白玻璃样式，
/// 任何封面取色下都清晰。
class _EntryChip extends StatelessWidget {
  const _EntryChip({
    required this.icon,
    required this.label,
    this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.16),
      shape: StadiumBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: 0.45)),
      ),
      child: InkWell(
        onTap: onPressed,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: Colors.white.withValues(alpha: 0.92)),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.96),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
