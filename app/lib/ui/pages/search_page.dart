import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/errors.dart';
import '../../core/history.dart';
import '../../core/lx_catalog.dart';
import '../../core/lx_runtime.dart';
import '../../core/logging.dart';
import '../../core/models.dart';
import '../../core/page_cache.dart';
import '../../core/source.dart';
import '../../main.dart';
import '../widgets/cover.dart';
import '../widgets/skeleton.dart';
import '../widgets/track_tile.dart';
import 'album_page.dart';
import 'artist_page.dart';
import 'playlist_page.dart';

/// 搜索页：按播放音源分流。
/// * 汽水：搜索历史 + 官方热搜 + 联想词 + 综合搜索
///   （单曲 / 音乐人 / 专辑 / 歌单）；
/// * 其他音源：平台内搜索（酷我/网易云，免签接口），结果为平台曲目
///   （可直接播放，走音源脚本取流），无联想词。
///
/// 入口在发现页顶部搜索栏（autofocus：从发现页进入直接弹键盘）。
class SearchPage extends StatelessWidget {
  const SearchPage({super.key, this.autofocus = false});

  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sourceStore,
      builder: (context, _) => sourceStore.isLx
          ? LxSearchPage(autofocus: autofocus)
          : SodaSearchPage(autofocus: autofocus),
    );
  }
}

/// 汽水搜索页（原内容）。
class SodaSearchPage extends StatefulWidget {
  const SodaSearchPage({super.key, this.autofocus = false});

  /// 进入即聚焦输入框（从发现页搜索栏点进来时）。
  final bool autofocus;

  @override
  State<SodaSearchPage> createState() => _SodaSearchPageState();
}

class _SodaSearchPageState extends State<SodaSearchPage> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  List<String> _suggests = [];
  List<String> _history = [];
  List<String> _hotWords = const [];
  SearchResults? _results;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reloadHistory();
    _loadHotWords();
  }

  Future<void> _reloadHistory() async {
    final words = await SearchHistory.load();
    if (mounted) setState(() => _history = words);
  }

  /// 官方热搜词（空态展示；SWR——上次缓存先上屏，后台刷新；失败静默）。
  Future<void> _loadHotWords() async {
    final cached = await PageCache.readList('hotwords', 'words',
        (json) => json['word']?.toString() ?? '');
    if (mounted && cached.isNotEmpty && _hotWords.isEmpty) {
      setState(() => _hotWords = cached);
    }
    try {
      final words = await Api.hotWords();
      if (mounted && words.isNotEmpty) {
        setState(() => _hotWords = words);
        unawaited(PageCache.writeJson('hotwords',
            {'words': words.map((word) => {'word': word}).toList()}));
      }
    } catch (error) {
      appLog('search: 热搜词拉取失败（忽略）: $error');
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    // suffix 清空按钮的显隐依赖输入内容，这里必须重建一次
    setState(() {});
    if (text.trim().isEmpty) {
      setState(() => _suggests = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final words = await Api.suggest(text.trim());
        if (mounted && _controller.text.trim() == text.trim()) {
          setState(() => _suggests = words.take(8).toList());
        }
      } catch (_) {
        // 联想失败静默
      }
    });
  }

  Future<void> _search(String keyword) async {
    keyword = keyword.trim();
    if (keyword.isEmpty) return;
    _debounce?.cancel();
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _suggests = [];
    });
    await SearchHistory.record(keyword);
    await _reloadHistory();
    try {
      final results = await Api.searchAll(keyword);
      if (mounted) setState(() => _results = results);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: widget.autofocus,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          onChanged: _onChanged,
          decoration: InputDecoration(
            hintText: '搜索歌曲 / 音乐人 / 专辑 / 歌单',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(() {
                      _controller.clear();
                      _suggests = [];
                      _results = null;
                    }),
                  ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(22),
              borderSide: BorderSide.none,
            ),
            filled: true,
          ),
        ),
      ),
      body: _suggests.isNotEmpty
          ? ListView.builder(
              itemCount: _suggests.length,
              itemBuilder: (context, index) => ListTile(
                leading: const Icon(Icons.search),
                title: Text(_suggests[index]),
                onTap: () {
                  _controller.text = _suggests[index];
                  _search(_suggests[index]);
                },
              ),
            )
          : _buildResults(),
    );
  }

  /// 搜索历史 + 官方热搜（无输入且无结果时展示）。
  Widget _buildHistory() {
    final scheme = Theme.of(context).colorScheme;
    if (_history.isEmpty && _hotWords.isEmpty) {
      return const Center(child: Text('输入关键词开始搜索'));
    }
    return ListView(
      children: [
        if (_hotWords.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                Icon(Icons.local_fire_department,
                    size: 18, color: Colors.orange.shade700),
                const SizedBox(width: 6),
                Text('热门搜索',
                    style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final word in _hotWords)
                  InputChip(
                    label: Text(word),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      _controller.text = word;
                      _search(word);
                    },
                  ),
              ],
            ),
          ),
        ],
        if (_history.isEmpty) const SizedBox.shrink()
        else ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
          child: Row(
            children: [
              Text('搜索历史',
                  style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              IconButton(
                tooltip: '清空搜索历史',
                icon: Icon(Icons.delete_outline,
                    size: 20, color: scheme.outline),
                onPressed: () async {
                  await SearchHistory.clear();
                  await _reloadHistory();
                },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final word in _history)
                InputChip(
                  label: Text(word),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _controller.text = word;
                    _search(word);
                  },
                  onDeleted: () async {
                    await SearchHistory.remove(word);
                    await _reloadHistory();
                  },
                ),
            ],
          ),
        ),
        ],
      ],
    );
  }

  Widget _buildResults() {
    if (_loading) {
      return const SkeletonBody(count: 8);
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!),
            ),
            FilledButton.tonal(
              onPressed: () => _search(_controller.text),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final results = _results;
    if (results == null) {
      return _buildHistory();
    }
    if (results.tracks.isEmpty &&
        results.artists.isEmpty &&
        results.albums.isEmpty &&
        results.playlists.isEmpty) {
      return const Center(child: Text('没有找到相关内容'));
    }
    return ListView(
      children: [
        _section('单曲', Icons.music_note, results.tracks.length),
        ...results.tracks.map(
          (track) => TrackTile(track: track, queue: results.tracks),
        ),
        if (results.playlists.isNotEmpty) ...[
          _section('歌单', Icons.queue_music, results.playlists.length),
          ...results.playlists.map(_playlistTile),
        ],
        if (results.artists.isNotEmpty) ...[
          _section('音乐人', Icons.person, results.artists.length),
          ...results.artists.map(
            (artist) => ListTile(
              leading: ClipOval(
                child: CoverImage(url: artist.avatar, size: 48),
              ),
              title: Text(artist.name),
              subtitle: Text('单曲 ${artist.trackCount} · 粉丝 ${artist.followerCount}'),
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
            ),
          ),
        ],
        if (results.albums.isNotEmpty) ...[
          _section('专辑', Icons.album, results.albums.length),
          ...results.albums.map(
            (album) => ListTile(
              leading: CoverImage(url: album.cover, size: 48),
              title: Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${album.artist} · ${album.trackCount} 首'),
              trailing: const Icon(Icons.chevron_right),
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
    );
  }

  Widget _playlistTile(PlaylistItem playlist) {
    return ListTile(
      leading: CoverImage(url: playlist.cover, size: 48),
      title: Text(playlist.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [if (playlist.creator.isNotEmpty) playlist.creator, '${playlist.trackCount} 首']
            .join(' · '),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlaylistPage(
            title: playlist.title,
            playlistId: playlist.id,
            item: playlist,
                      ),
        ),
      ),
    );
  }

  Widget _section(String title, IconData icon, int count) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 6),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 8),
          Text('$count', style: TextStyle(color: scheme.outline, fontSize: 12)),
        ],
      ),
    );
  }
}

/// 其他音源搜索页：平台内搜索（免签接口），结果为可播放的平台曲目。
class LxSearchPage extends StatefulWidget {
  const LxSearchPage({super.key, this.autofocus = false});

  /// 进入即聚焦输入框（从发现页搜索栏点进来时）。
  final bool autofocus;

  @override
  State<LxSearchPage> createState() => _LxSearchPageState();
}

class _LxSearchPageState extends State<LxSearchPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<Track> _tracks = [];
  List<String> _history = [];
  String _platform = 'kw';
  String _keyword = '';
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _platform = sourceStore.platform;
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600 && !_loading && _hasMore) {
        _loadMore();
      }
    });
    _reloadHistory();
    sourceStore.addListener(_onSourceStoreChanged);
    unawaited(_refreshPlatforms());
  }

  /// 刷新脚本就绪状态：平台切换按钮的可选项随就绪脚本动态罗列。
  Future<void> _refreshPlatforms() async {
    await LxRuntime.instance.ensureStarted();
    await LxRuntime.instance.refreshStatus();
    if (mounted) setState(() {});
  }

  /// 平台在首页/发现页切换时跟随（当前平台无结果时可换平台再搜）。
  void _onSourceStoreChanged() {
    if (!mounted) return;
    final platform = sourceStore.platform;
    if (platform != _platform) {
      _platform = platform;
      if (_keyword.isNotEmpty) _search(_keyword);
    }
  }

  @override
  void dispose() {
    sourceStore.removeListener(_onSourceStoreChanged);
    _scroll.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _reloadHistory() async {
    final words = await SearchHistory.load();
    if (mounted) setState(() => _history = words);
  }

  Future<void> _search(String keyword) async {
    keyword = keyword.trim();
    if (keyword.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _keyword = keyword;
      _tracks.clear();
      _page = 0;
      _hasMore = true;
      _loading = true;
      _error = null;
    });
    await SearchHistory.record(keyword);
    await _reloadHistory();
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading && _tracks.isNotEmpty) return;
    if (_keyword.isEmpty || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final result = await Api.platformTracks(
        _platform,
        _keyword,
        page: _page + 1,
      );
      if (!mounted) return;
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: widget.autofocus,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          decoration: InputDecoration(
            hintText: '在${lxPlatformName(_platform)}搜歌曲',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(() {
                      _controller.clear();
                      _tracks.clear();
                      _keyword = '';
                      _error = null;
                    }),
                  ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(22),
              borderSide: BorderSide.none,
            ),
            filled: true,
          ),
        ),
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
      body: Column(
        children: [
          // 平台切换（与首页/发现联动；曲库平台与激活脚本解耦，全平台可选）
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: SegmentedButton<String>(
              segments: [
                for (final item in LxRuntime.searchSupportedPlatforms)
                  ButtonSegment(
                    value: item,
                    label: Text(lxPlatformName(item)),
                  ),
              ],
              selected: {_platform},
              onSelectionChanged: (value) async {
                await sourceStore.switchPlatform(value.first);
              },
            ),
          ),
          Expanded(
            child: _keyword.isEmpty
                ? _buildEmpty(scheme)
                : _buildResults(scheme),
          ),
        ],
      ),
    );
  }

  /// 空态：热词 + 搜索历史。
  Widget _buildEmpty(ColorScheme scheme) {
    if (_history.isEmpty) {
      return ListView(
        children: [
          _hotWordsSection(scheme),
        ],
      );
    }
    return ListView(
      children: [
        _hotWordsSection(scheme),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
          child: Row(
            children: [
              Text('搜索历史', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              IconButton(
                tooltip: '清空搜索历史',
                icon: Icon(Icons.delete_outline,
                    size: 20, color: scheme.outline),
                onPressed: () async {
                  await SearchHistory.clear();
                  await _reloadHistory();
                },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final word in _history)
                InputChip(
                  label: Text(word),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _controller.text = word;
                    _search(word);
                  },
                  onDeleted: () async {
                    await SearchHistory.remove(word);
                    await _reloadHistory();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _hotWordsSection(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Row(
            children: [
              Icon(Icons.local_fire_department,
                  size: 18, color: Colors.orange.shade700),
              const SizedBox(width: 6),
              Text('热门搜索', style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final word in lxHotWords)
                InputChip(
                  label: Text(word),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _controller.text = word;
                    _search(word);
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildResults(ColorScheme scheme) {
    if (_loading && _tracks.isEmpty) {
      return const SkeletonBody(count: 8);
    }
    if (_error != null && _tracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!),
            ),
            FilledButton.tonal(
              onPressed: () => _search(_keyword),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_tracks.isEmpty) {
      return Center(
        child: Text('${lxPlatformName(_platform)}没有找到「$_keyword」'),
      );
    }
    return ListView.builder(
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
        return TrackTile(track: _tracks[index], queue: _tracks);
      },
    );
  }
}
