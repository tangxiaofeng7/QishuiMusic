/// 业务 API：把 Rust FFI 的同步调用包成异步（后台 isolate 执行）。

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'cache_index.dart';
import 'ffi.dart';
import 'logging.dart';
import 'lx_runtime.dart';
import 'lx_speed_test.dart' show lxSpeedKey;
import 'models.dart';
import 'net.dart';
import 'page_cache.dart';
import 'speed.dart';
import 'store.dart' as store;

/// lx 出链候选：直链 + 展示标签 + 下载 tag + 出链脚本 id。
typedef LxHit = ({String url, String label, String tag, String scriptId});

class Api {
  const Api._();

  /// 直链请求 UA：直链 CDN 普遍校验请求方（QQ 的
  /// dl.stream.qqmusic.qq.com 对非浏览器 UA 一律 403）。
  static const kDirectUrlUA =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_1_1 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 '
      'Mobile/15E148 Safari/604.1';

  /// Rust 会话就绪门：main 启动时把 configure/ping 的 Future 挂上来，
  /// 首屏 UI 不再等它（runApp 立即执行），业务请求在此自动排队。
  static Future<void> _sessionReady = Future.value();

  static set sessionReady(Future<void> future) => _sessionReady = future;

  static Future<dynamic> _call(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    await _sessionReady;
    return Isolate.run(() => NativeFfi.instance.request(method, params));
  }

  /// 连通性/配置检查。
  static Future<Map<String, dynamic>> ping() async =>
      Map<String, dynamic>.from(await _call('ping') as Map);

  /// 配置（登录后重建会话）。
  static Future<Map<String, dynamic>> configure(
    Map<String, dynamic> config,
  ) async {
    return Isolate.run(() => NativeFfi.instance.init(config));
  }

  static Future<AccountInfo> account() async =>
      AccountInfo.fromJson(await _call('account'));

  /// 取流梯子诊断（selftest/日志用）：逐档偏好 resolve，报告每档实际命中的
  /// 层（web/h5/mobile/pc）与档位——钉死「免签名直取」链路的档位上限。
  static Future<List<Map<String, dynamic>>> streamLadder(Track track) async {
    final data = await _call('streamLadder', {'track': track.toJson()});
    return (data['rungs'] as List? ?? const [])
        .map((rung) => Map<String, dynamic>.from(rung as Map))
        .toList();
  }

  static Future<
    ({String token, String scanUrl, String qrImage, int expireTime})
  >
  qrCreate() async {
    final data = await _call('qrCreate');
    return (
      token: data['token']?.toString() ?? '',
      scanUrl: data['scanUrl']?.toString() ?? '',
      qrImage: data['qrImage']?.toString() ?? '',
      expireTime: (data['expireTime'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<QrLoginResult> qrCheck(String token) async =>
      QrLoginResult.fromJson(await _call('qrCheck', {'token': token}));

  static Future<SearchResults> searchAll(String keyword) async =>
      SearchResults.fromJson(await _call('searchAll', {'keyword': keyword}));

  static Future<List<String>> suggest(String keyword) async {
    final data = await _call('suggest', {'keyword': keyword});
    return (data as List).map((item) => item.toString()).toList();
  }

  static Future<List<SceneItem>> scenes() async {
    final data = await _call('scenes');
    return (data as List)
        .whereType<Map<String, dynamic>>()
        .map(SceneItem.fromJson)
        .toList();
  }

  static Future<FeedPage> feed({
    int fetchCounter = 0,
    int didFirstUseTime = 0,
    int? sceneModeId,
    String? subQueueType,
  }) async {
    final data = await _call('feed', {
      'fetchCounter': fetchCounter,
      'didFirstUseTime': didFirstUseTime,
      'sceneModeId': ?sceneModeId,
      if (subQueueType != null && subQueueType.isNotEmpty)
        'subQueueType': subQueueType,
    });
    final videos = (data['videos'] as num?)?.toInt() ?? 0;
    if (videos > 0) {
      appLog('feed: 跳过 $videos 个视频条目（抖音视频暂不支持）');
    }
    return FeedPage.fromJson(data);
  }

  static Future<
    ({List<PlaylistItem> playlists, bool hasMore, String nextCursor})
  >
  myPlaylists({String cursor = '', int count = 50}) async {
    final data = await _call('myPlaylists', {'cursor': cursor, 'count': count});
    return (
      playlists: (data['playlists'] as List)
          .whereType<Map<String, dynamic>>()
          .map(PlaylistItem.fromJson)
          .toList(),
      hasMore: data['hasMore'] == true,
      nextCursor: data['nextCursor']?.toString() ?? '',
    );
  }

  static Future<List<Track>> playlistTracks(String playlistId) async {
    final data = await _call('playlistTracks', {'playlistId': playlistId});
    return _tracksWithoutVideos(data, '歌单');
  }

  /// 歌单详情内存 memo（5 分钟 TTL）：同一会话反复进出同一歌单秒开。
  /// 容量上限防长期会话膨胀。
  static final Map<
    String,
    (DateTime, ({List<Track> tracks, PlaylistMeta? meta}))
  >
  _playlistMemo = {};

  /// 歌单详情：曲目 + 元数据（同一回包附带，零额外请求）。
  static Future<({List<Track> tracks, PlaylistMeta? meta})> playlistDetail(
    String playlistId,
  ) async {
    final hit = _playlistMemo[playlistId];
    if (hit != null &&
        DateTime.now().difference(hit.$1) < const Duration(minutes: 5)) {
      return hit.$2;
    }
    final data = await _call('playlistTracks', {'playlistId': playlistId});
    final raw = data['playlist'];
    final result = (
      tracks: _tracksWithoutVideos(data, '歌单'),
      meta: raw is Map && raw.isNotEmpty
          ? PlaylistMeta.fromJson(Map<String, dynamic>.from(raw))
          : null,
    );
    if (_playlistMemo.length > 60) _playlistMemo.clear();
    _playlistMemo[playlistId] = (DateTime.now(), result);
    return result;
  }

  /// 我收藏的歌单（他人歌单）。
  static Future<List<PlaylistItem>> collectedPlaylists() async {
    final data = await _call('collectedPlaylists');
    return (data['playlists'] as List)
        .whereType<Map<String, dynamic>>()
        .map(PlaylistItem.fromJson)
        .toList();
  }

  /// 发现页内容流（歌单广场/排行榜）。
  ///
  /// [blockType] 用官方场景名：`discovery_playlist`=歌单广场、
  /// `discovery_chart`/`discover_track_top_list`=排行榜、`discovery_radio`=电台。
  static Future<DiscoverPage> discoverMix(
    String blockType, {
    String cursor = '',
    int count = 20,
    int subChannelId = 0,
  }) async {
    final data = await _call('discoverMix', {
      'blockType': blockType,
      'subChannelId': subChannelId,
      'cursor': cursor,
      'count': count,
    });
    return DiscoverPage.fromJson(Map<String, dynamic>.from(data));
  }

  /// 推荐歌单（官方「为你推荐」歌单列表）。
  static Future<List<PlaylistItem>> recommendPlaylists() async {
    final data = await _call('recommendPlaylists');
    return (data['playlists'] as List)
        .whereType<Map<String, dynamic>>()
        .map(PlaylistItem.fromJson)
        .toList();
  }

  /// 我关注的艺人（分页）。
  static Future<({List<ArtistItem> artists, bool hasMore, String nextCursor})>
  collectedArtists({String cursor = '', int count = 50}) async {
    final data = await _call('collectedArtists', {
      'cursor': cursor,
      'count': count,
    });
    return (
      artists: (data['artists'] as List)
          .whereType<Map<String, dynamic>>()
          .map(ArtistItem.fromJson)
          .toList(),
      hasMore: data['hasMore'] == true,
      nextCursor: data['nextCursor']?.toString() ?? '',
    );
  }

  /// 我收藏的专辑（分页）。
  static Future<({List<AlbumItem> albums, bool hasMore, String nextCursor})>
  collectedAlbums({String cursor = '', int count = 30}) async {
    final data = await _call('collectedAlbums', {
      'cursor': cursor,
      'count': count,
    });
    return (
      albums: (data['albums'] as List)
          .whereType<Map<String, dynamic>>()
          .map(
            (item) => AlbumItem.fromJson({
              ...item,
              'title': item['name'],
              'artist': item['artists'],
            }),
          )
          .toList(),
      hasMore: data['hasMore'] == true,
      nextCursor: data['nextCursor']?.toString() ?? '',
    );
  }

  /// 相似歌曲（官方播放页「相似歌曲」；接口受限时抛错，UI 隐藏入口）。
  static Future<List<Track>> relatedTracks(
    String trackId, {
    int count = 30,
  }) async {
    final data = await _call('relatedTracks', {
      'trackId': trackId,
      'count': count,
    });
    final tracks = (data['tracks'] as List)
        .whereType<Map<String, dynamic>>()
        .map(Track.fromJson)
        .toList();
    // 服务端可能混入当前曲本身，去掉
    return tracks.where((track) => track.id != trackId).toList();
  }

  /// 我的音乐墙（最爱曲目 + 口味标签；PC 形态端点）。
  static Future<({List<Track> tracks, List<MusicWallTag> tags})>
  musicWall() async {
    final data = await _call('musicWall');
    return (
      tracks: parseTracks(data['tracks']),
      tags: (data['tags'] as List)
          .whereType<Map<String, dynamic>>()
          .map(MusicWallTag.fromJson)
          .toList(),
    );
  }

  /// 电台列表（官方发现页 discover_radio 电台站）。
  static Future<List<RadioStation>> radioList() async {
    final data = await _call('radioList');
    return (data['stations'] as List)
        .whereType<Map<String, dynamic>>()
        .map(RadioStation.fromJson)
        .toList();
  }

  /// 电台列表调试信息（空列表时自检定位用；正常 UI 不消费）。
  static Future<dynamic> radioListDebug() async => _call('radioList');

  /// 电台曲目队列（官方无限电台）。`playedIds` 传已播曲目让服务端换血；
  /// 回包同参重拉会轮换，去重由调用方按 id 做。
  static Future<({List<Track> tracks, bool hasMore})> radioTracks(
    String radioId, {
    List<String> playedIds = const [],
    int count = 20,
  }) async {
    final data = await _call('radioTracks', {
      'radioId': radioId,
      'playedIds': playedIds,
      'count': count,
    });
    return (
      tracks: parseTracks(data['tracks']),
      hasMore: data['hasMore'] == true,
    );
  }

  /// 官方热搜词（搜索页空态）。
  static Future<List<String>> hotWords() async {
    final data = await _call('hotWords');
    return (data as List).map((item) => item.toString()).toList();
  }

  /// 艺人详情（含热门歌曲）。
  static Future<ArtistDetail> artistDetail(String artistId) async =>
      ArtistDetail.fromJson(
        Map<String, dynamic>.from(
          await _call('artistDetail', {'artistId': artistId}),
        ),
      );

  /// 艺人单曲（分页）。
  static Future<({List<Track> tracks, bool hasMore, String nextCursor})>
  artistTracks(String artistId, {String cursor = '', int count = 50}) async {
    final data = await _call('artistTracks', {
      'artistId': artistId,
      'cursor': cursor,
      'count': count,
    });
    return (
      tracks: parseTracks(data['tracks']),
      hasMore: data['hasMore'] == true,
      nextCursor: data['nextCursor']?.toString() ?? '',
    );
  }

  /// 艺人专辑（分页）。
  static Future<({List<AlbumItem> albums, bool hasMore, String nextCursor})>
  artistAlbums(String artistId, {String cursor = '', int count = 50}) async {
    final data = await _call('artistAlbums', {
      'artistId': artistId,
      'cursor': cursor,
      'count': count,
    });
    return (
      albums: (data['albums'] as List)
          .whereType<Map<String, dynamic>>()
          .map(AlbumItem.fromJson)
          .toList(),
      hasMore: data['hasMore'] == true,
      nextCursor: data['nextCursor']?.toString() ?? '',
    );
  }

  /// 曲目列表 + 视频条目处理：全是视频时给出可读错误而不是无声的空列表。
  static List<Track> _tracksWithoutVideos(
    Map<String, dynamic> data,
    String what,
  ) {
    final tracks = parseTracks(data['tracks']);
    final videos = (data['videos'] as num?)?.toInt() ?? 0;
    if (tracks.isEmpty && videos > 0) {
      appLog('$what: $videos 个条目是抖音视频（暂不支持），无曲目');
      throw '$what里共 $videos 个视频曲目，暂不支持播放';
    }
    return tracks;
  }

  /// 专辑曲目 + 元信息（发行时间/简介，公开分享页解析，无需登录）。
  static Future<({List<Track> tracks, AlbumMeta? meta})> albumDetail(
    String albumId,
  ) async {
    final data = await _call('albumTracks', {'albumId': albumId});
    final raw = data['album'];
    return (
      tracks: parseTracks(data['tracks']),
      meta: raw is Map && raw.isNotEmpty
          ? AlbumMeta.fromJson(Map<String, dynamic>.from(raw))
          : null,
    );
  }

  /// 专辑曲目（公开分享页，无需登录）。
  static Future<List<Track>> albumTracks(String albumId) async {
    final data = await _call('albumTracks', {'albumId': albumId});
    return parseTracks(data['tracks']);
  }

  static Future<List<Track>> likedSongs() async {
    final data = await _call('likedSongs');
    return _tracksWithoutVideos(data, '我喜欢的音乐');
  }

  /// 抖音收藏的音乐（type=4 系统歌单）。
  static Future<List<Track>> douyinFavorites() async {
    final data = await _call('douyinFavorites');
    return _tracksWithoutVideos(data, '抖音收藏的音乐');
  }

  /// 歌词 + 翻译 + 热门评论（translations: 语言码 → LRC 文本，无翻译为空
  /// Map；comments 为 SEO 分享页内嵌的热门评论，无则空列表）。
  ///
  /// 磁盘缓存（SWR）：歌词/翻译/评论随曲目基本不变，命中即秒回
  /// （对齐官方客户端的歌词秒显）；有内容才落盘，超过 400 首删最旧。
  static Future<
    ({
      String lrc,
      Map<String, String> translations,
      List<TrackComment> comments,
      int commentCount,
    })
  >
  lyricsWithTranslation(String trackId) async {
    final cached = await PageCache.readJson('lyric-$trackId');
    if (cached != null) return _parseLyricsPayload(cached);
    final data = await _call('lyrics', {'trackId': trackId});
    final parsed = _parseLyricsPayload(Map<String, dynamic>.from(data));
    if (parsed.lrc.trim().isNotEmpty ||
        parsed.comments.isNotEmpty ||
        parsed.translations.isNotEmpty) {
      unawaited(_cacheLyrics(trackId, data));
    }
    return parsed;
  }

  /// 平台曲目歌词（kw/wy/kg/tx 免签 LRC；网易云带翻译）。
  /// 缓存键与汽水歌词一致（`lyric-<trackId>`，同一 400 条 LRU）。
  static Future<
      ({
        String lrc,
        Map<String, String> translations,
        List<TrackComment> comments,
        int commentCount,
      })
    >
    platformLyrics(String platform, String songmid, String trackId) async {
    final cached = await PageCache.readJson('lyric-$trackId');
    if (cached != null) return _parseLyricsPayload(cached);
    final data = await _call('platformLyric', {
      'platform': platform,
      'songmid': songmid,
    });
    final translation = data['translation']?.toString() ?? '';
    final payload = <String, dynamic>{
      'lrc': data['lyric']?.toString() ?? '',
      if (translation.trim().isNotEmpty) 'translations': {'cn': translation},
    };
    final parsed = _parseLyricsPayload(payload);
    if (parsed.lrc.trim().isNotEmpty) {
      unawaited(_cacheLyrics(trackId, payload));
    }
    return parsed;
  }

  static Future<void> _cacheLyrics(
    String trackId,
    Map<String, dynamic> data,
  ) async {    await PageCache.writeJson('lyric-$trackId', data);
    try {
      final dir = Directory('${await store.Settings.resolveCacheDir()}/pages');
      final files =
          dir
              .listSync()
              .whereType<File>()
              .where((file) => file.path.contains('lyric-'))
              .toList()
            ..sort(
              (a, b) => a.lastAccessedSync().compareTo(b.lastAccessedSync()),
            );
      while (files.length > 400) {
        files.removeAt(0).deleteSync();
      }
    } catch (_) {}
  }

  static ({
    String lrc,
    Map<String, String> translations,
    List<TrackComment> comments,
    int commentCount,
  })
  _parseLyricsPayload(Map<String, dynamic> data) {
    final translations = <String, String>{};
    final raw = data['translations'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final text = entry.value?.toString() ?? '';
        if (text.trim().isNotEmpty) translations[entry.key.toString()] = text;
      }
    }
    final comments = ((data['comments'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TrackComment.fromJson)
        .toList();
    var commentCount = 0;
    if (data['commentCount'] is num) {
      commentCount = (data['commentCount'] as num).toInt();
    }
    return (
      lrc: data['lrc']?.toString() ?? '',
      translations: translations,
      comments: comments,
      commentCount: commentCount,
    );
  }

  /// 下载 + 解密到本地缓存，返回可播放文件路径。
  ///
  /// 按曲目平台与当前音源分流：
  /// * 平台曲目（platform=kw/wy，来自 LX 模式曲库/最近播放/喜欢）：
  ///   只走 lx 脚本链（songmid 直取，未命中再按标题跨平台匹配），
  ///   不回落汽水——汽水没有这首歌，回落只会白跑一轮探测；
  /// * default：汽水账号优先（内部已挂签名服务实现音质限免：免费曲
  ///   全档位；VIP 曲按账号权益，无权益为试听）；试听档且开启回落时
  ///   走外部链（lx 脚本），全失败回拿汽水试听；
  /// * lx：外部链优先（先查已缓存的外部文件），未命中回落汽水
  ///   （forceTrial 跳过重复的试听探测）。
  ///
  /// [forceDownload]：播放器直链流式播放失败后的回退调用——跳过
  /// 流式直链返回，强制整曲下载落盘拿本地文件。
  ///
  /// [refreshQuality]：音质档位切换重载——绕过本地缓存直通，按新档位
  /// 重新取流（否则永远播旧档缓存文件）。
  static Future<PreparedTrack> prepareTrack(
    Track track, {
    bool forceDownload = false,
    bool refreshQuality = false,
  }) async {
    // 本地整曲直通（零网络）：「已缓存曲目」点播与会话恢复的曲目自带
    // 已验证的缓存文件路径，直接放本地文件。Rust 侧的缓存命中按当前
    // 音质设置的文件名 tag 匹配——设置变过档就整曲重下，这里绕开它。
    if (!refreshQuality && track.cachedPath.isNotEmpty) {
      final file = File(track.cachedPath);
      if (await file.exists()) {
        return PreparedTrack(
          path: track.cachedPath,
          quality: track.cachedQuality,
          cached: true,
          origin: track.cachedQuality.startsWith('外部·')
              ? _extOrigin(track.cachedQuality)
              : '汽水账号',
          sizeBytes: await _fileSize(track.cachedPath),
        );
      }
      // 文件已被删（清缓存/手动清理）：落回常规链路
    }
    final source = store.activeSettings?.sourceMode ?? 'default';
    // 平台曲目：与本机音源模式无关，永远走脚本链（最近播放/我喜欢的
    // 全局共享平台曲目，汽水模式下也要能播）。
    if (const {'kw', 'wy', 'kg', 'tx'}.contains(track.platform)) {
      return _preparePlatformTrack(track, refreshQuality: refreshQuality);
    }
    if (source == 'lx') {
      // 切档重载必须绕过秒播缓存：ext 条目按曲目 id 记、不分音质，
      // 命中即把切档永远锁死在旧档文件（标签/大小随之纹丝不动）。
      final cached = refreshQuality ? null : await _cachedExt(track);
      if (cached != null) return cached;
      final ext = await _resolveExt(track);
      if (ext != null) {
        final file = await _downloadExt(ext.url, track, ext.tag);
        if (file != null) {
          await CacheIndex.record(
            track,
            quality: ext.label,
            path: file,
            source: 'ext',
          );
          return PreparedTrack(
            path: file,
            quality: ext.label,
            cached: false,
            origin: _extOrigin(ext.label),
            sizeBytes: await _fileSize(file),
          );
        }
        _demoteDeadScript(ext.scriptId);
      }
      // 外部链全失败：回落汽水试听——实际取流是汽水，展示以实际为准
      final data = await _call('prepareTrack', {
        'track': track.toJson(),
        'forceTrial': true,
        if (forceDownload) 'forceDownload': true,
      });
      return _record(
          track, _withOrigin(PreparedTrack.fromJson(data), '汽水账号'), 'soda');
    }
    var data = await _call('prepareTrack', {
      'track': track.toJson(),
      if (forceDownload) 'forceDownload': true,
    });
    if (data['needsExt'] == true) {
      final ext = await _resolveExt(track);
      if (ext != null) {
        final file = await _downloadExt(ext.url, track, ext.tag);
        if (file != null) {
          await CacheIndex.record(
            track,
            quality: ext.label,
            path: file,
            source: 'ext',
          );
          return PreparedTrack(
            path: file,
            quality: ext.label,
            cached: false,
            origin: _extOrigin(ext.label),
            sizeBytes: await _fileSize(file),
          );
        }
        _demoteDeadScript(ext.scriptId);
      }
      // 外部链全失败：回拿汽水试听
      data = await _call('prepareTrack', {
        'track': track.toJson(),
        'forceTrial': true,
        if (forceDownload) 'forceDownload': true,
      });
    }
    final prepared = PreparedTrack.fromJson(data);
    // 免签名直取层（h5/mobile）命中时在音源名上点名：设置里没配签名服务
    // 也能拿到高音质的通道，用户从播放页就能确认走的是哪条链。
    final layerSuffix = switch (prepared.layer) {
      'h5' => '（h5 免签直取）',
      'mobile' => '（移动端免签直取）',
      _ => '',
    };
    final sodaOrigin = '汽水账号$layerSuffix';
    return _record(track, _withOrigin(prepared, sodaOrigin), 'soda');
  }

  /// 外部链标签（「外部·独家LX 320k」/「外部·酷我 128k」）→ 实际取流来源
  /// （「取流·独家LX」/「取流·酷我」）。
  static String _extOrigin(String label) {
    if (!label.startsWith('外部·')) return '取流脚本';
    final rest = label.substring('外部·'.length);
    final cut = rest.lastIndexOf(' ');
    return cut > 0 ? '取流·${rest.substring(0, cut)}' : '取流·$rest';
  }

  static PreparedTrack _withOrigin(PreparedTrack prepared, String origin) =>
      PreparedTrack(
        path: prepared.path,
        quality: prepared.quality,
        cached: prepared.cached,
        origin: origin,
        layer: prepared.layer,
        url: prepared.url,
        ua: prepared.ua,
        sizeBytes: prepared.sizeBytes,
      );

  /// 外部链无 Rust size 回包：读本地文件大小补齐（失败不挡播放）。
  static Future<int?> _fileSize(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return null;
    }
  }

  /// prepare 成功后把可读元数据记进缓存索引（供「已缓存曲目」展示点播）。
  static Future<PreparedTrack> _record(
    Track track,
    PreparedTrack prepared,
    String source,
  ) async {
    if (prepared.path.isNotEmpty && !prepared.quality.contains('试听')) {
      try {
        await CacheIndex.record(
          track,
          quality: prepared.quality,
          path: prepared.path,
          source: source,
        );
      } catch (error) {
        appLog('cache-index: 记录失败(忽略): $error');
      }
    }
    return prepared;
  }

  /// 已缓存的外部整曲（lx 模式秒播，不走解析链）。
  static Future<PreparedTrack?> _cachedExt(Track track) async {
    try {
      for (final entry in await CacheIndex.list()) {
        if (entry.id == track.id && entry.source == 'ext') {
          return PreparedTrack(
            path: entry.path,
            quality: entry.quality,
            cached: true,
            origin: _extOrigin(entry.quality),
            sizeBytes: await _fileSize(entry.path),
          );
        }
      }
    } catch (_) {}
    return null;
  }

  // -------------------------------------------------------------------------
  // 外部音源解析链（lx-music 式）
  // -------------------------------------------------------------------------

  /// 选定脚本（lx 模式激活音源）首攻失败的会话内熔断：失败原因 + 对应
  /// 脚本 id。首攻要「等脚本就绪（最长 18s）+ 逐档出链」，已知失败的
  /// 脚本不能在后续每层兜底、每一首歌上重演一遍等待。切换脚本、脚本
  /// 重载/测速成功（[resetActiveScriptFuse]）即复位。
  static String? _activeHeadFuse;
  static String _activeHeadFuseId = '';

  static const _qualityTiers = {
    '': ['flac', '320k', '128k'],
    'spatial': ['flac', '320k', '128k'],
    'hires': ['flac', 'flac24bit', '320k'],
    'lossless': ['flac', 'flac24bit', '320k'],
    'highest': ['320k', '128k'],
    'medium': ['128k'],
    'low': ['128k'],
  };

  /// LX 脚本链的音质候选：
  /// * LX 模式 + 用户显式选了档位（settings.lxQuality）→ 该档优先、
  ///   逐级回落（脚本不支持的档位由 _urlFromScripts 自然跳过）；
  /// * 其余（自动 / 汽水模式的 ext 回落链）→ 汽水档位映射（现状）。
  static List<String> _lxQualityCandidates() {
    final settings = store.activeSettings;
    final explicit = settings != null && settings.sourceMode == 'lx'
        ? settings.lxQuality
        : '';
    if (explicit.isEmpty) {
      return _qualityTiers[settings?.quality ?? ''] ?? _qualityTiers['']!;
    }
    return switch (explicit) {
      'flac24bit' => const ['flac24bit', 'flac', '320k', '128k'],
      'flac' => const ['flac', '320k', '128k'],
      '320k' => const ['320k', '128k'],
      '128k' => const ['128k'],
      _ => _qualityTiers['']!,
    };
  }

  static Future<({String url, String label, String tag, String scriptId})?> _resolveExt(
    Track track, {
    int maxHits = 1,
  }) async {
    final hits = await _resolveExtList(track, maxHits: maxHits);
    return hits.isEmpty ? null : hits.first;
  }

  /// 跨平台搜索解析，返回多个候选（下载层逐个换源重试用）。
  static Future<
      List<({String url, String label, String tag, String scriptId})>
  > _resolveExtList(Track track, {int maxHits = 1}) async {
    // 外部整曲统一走 lx 脚本链：kw/wy 平台搜索 → 逐脚本 musicUrl
    // （128k~无损；原生酷我直连已移除——脚本源已覆盖酷我）。
    // 总预算 12s：脚本源质量参差（部分被自家 API 限流），不设上限时
    // 单首解析实测可达 60-70s，把首播体验拖死；超时=视为未命中回落。
    try {
      await LxRuntime.instance.ensureStarted();
      final qualityCandidates = _lxQualityCandidates();
      final disabled =
          store.activeSettings?.lxDisabledScripts ?? const <String>[];
      final hidden = store.activeSettings?.lxHiddenScripts ?? const <String>[];
      // lx 模式且选定脚本：首攻要等脚本就绪（18s 上限）+ 出链 8s，预算
      // 相应放宽；汽水试听回落（default 模式）不等脚本，12s 足够。
      final activeHead = store.activeSettings?.sourceMode == 'lx' &&
          (store.activeSettings?.lxScript ?? '').isNotEmpty;
      final hits = await _resolveExtViaLx(
        track,
        qualityCandidates,
        disabled,
        hidden,
        maxHits: maxHits,
      ).timeout(
        Duration(seconds: activeHead ? 36 : 12),
        onTimeout: () {
          appLog('ext: lx 链路总预算用尽（${activeHead ? 36 : 12}s），回落');
          return const [];
        },
      );
      return hits;
    } catch (error) {
      appLog('ext: lx 链路失败: $error');
      return const [];
    }
  }

  /// 平台曲目取流（platform=kw/wy/kg/tx）：songmid 直取脚本链 → 未命中再按
  /// 标题跨平台搜索兜底。不回落汽水（汽水没有这首歌）。
  ///
  /// [refreshQuality]：音质切档重载——绕过秒播缓存重新取流（ext 条目不
  /// 分音质，命中会永远播旧档；回落到同档时下载层会重复落盘一次，可接受）。
  static Future<PreparedTrack> _preparePlatformTrack(
    Track track, {
    bool refreshQuality = false,
  }) async {
    final cached = refreshQuality ? null : await _cachedExt(track);
    if (cached != null) return cached;
    final candidates = await _resolvePlatformTrack(track);
    if (candidates.isEmpty) {
      // lx 模式下选定脚本是音源本身，失败要点名它——用户才知道该换源
      // 还是该测速，而不是一句笼统的「检查脚本是否就绪」。
      final settings = store.activeSettings;
      final activeId = settings?.lxScript ?? '';
      final script = settings?.sourceMode == 'lx' && activeId.isNotEmpty
          ? LxRuntime.instance.scriptById(activeId)
          : null;
      throw script != null
          ? '取流失败：当前音源「${script.name}」及其余通道均未出链；'
              '可到「设置 → 播放音源」更换音源，或到「取流脚本」测速'
          : '取流失败：请到「设置 → 播放音源 → 取流脚本」检查脚本'
              '是否就绪（当前曲目来自${track.platformLabel}）';
    }
    // 多候选逐个下载：个别脚本的直链会被 CDN 拒（403/超时），换源重试
    String? file;
    ({String url, String label, String tag, String scriptId})? hit;
    for (final candidate in candidates) {
      hit = candidate;
      file = await _downloadExt(candidate.url, track, candidate.tag);
      if (file != null) break;
      appLog('ext: 候选 ${candidate.tag} 下载失败，换下一个源');
      // 动态降权：直链下载失败（DNS/403/超时）的脚本即刻踢出「可用」
      // 组——脚本源会动态失效（测速时还活着，点歌时已死），不降权的
      // 话下一次点歌还是先撞同一个死源。
      speedStore.update(
        lxSpeedKey(candidate.scriptId),
        const SpeedResult(ms: 0, text: '直链不可达', ok: false),
      );
      // 选定脚本拿到直链但下载被拒：同样点亮首攻熔断——下一首直接走
      // 回退通道，不再每首都撞一次它的死 CDN。
      if (candidate.scriptId.isNotEmpty &&
          candidate.scriptId == (store.activeSettings?.lxScript ?? '') &&
          store.activeSettings?.sourceMode == 'lx') {
        _activeHeadFuse = '直链不可达';
        _activeHeadFuseId = candidate.scriptId;
      }
    }
    if (file == null || hit == null) throw '直链下载失败，稍后重试';
    await CacheIndex.record(
      track,
      quality: hit.label,
      path: file,
      source: 'ext',
    );
    return PreparedTrack(
      path: file,
      quality: hit.label,
      cached: false,
      origin: _extOrigin(hit.label),
      sizeBytes: await _fileSize(file),
    );
  }

  /// 平台曲目解析：选定脚本独占首攻（lx 模式）→ 未命中再脚本聚合，
  /// 全部落空按标题跨平台搜索兜底。
  static Future<List<LxHit>> _resolvePlatformTrack(Track track) async {
    // 首攻（对齐 lx-music「音源即脚本」）：选定脚本就是播放音源，
    // 先等它、用它；失败由其余就绪脚本聚合兜底（不含任何绕过脚本链
    // 的官方直连——出链通道完全收敛到用户选择的取流脚本）。
    final (headHit, headExclude) = await _activeHead(track);
    if (headHit != null) {
      appLog('ext: 平台曲目「${track.title}」由当前音源出链'
          '（${headHit.tag}）');
      return [headHit];
    }
    final hits = headExclude.isEmpty
        ? await _urlFromScriptsSafely(track)
        : await _urlFromScriptsSafely(track, activeHead: false);
    if (hits.isNotEmpty) {
      appLog('ext: 平台曲目解析「${track.title}」'
          '（${track.platform} ${track.songmid}，${hits.length} 个候选）');
      return hits;
    }
    // 直取未命中（无脚本支持该平台/全部失败）：按标题跨平台搜索兜底。
    // 搜索兜底同样要多候选——单候选直链被 CDN 拒（403/404）时整曲即死。
    return _resolveExtList(track, maxHits: 3);
  }

  /// 脚本直取（带整体预算；运行时未就绪等异常按无命中处理）。
  ///
  /// [activeHead]：先做选定脚本独占首攻（对齐 lx-music「音源即脚本」：
  /// lx 模式下选定脚本就是播放音源本身——等它就绪、只用它出链，命中
  /// 即整链返回）；false = 调用方已首攻失败，聚合链排除选定脚本，
  /// 不在同一预算里二次撞同一个死源。
  static Future<List<LxHit>> _urlFromScriptsSafely(
    Track track, {
    bool activeHead = true,
  }) async {
    try {
      await LxRuntime.instance.ensureStarted();
      var skip = _lxSkipSet();
      if (activeHead) {
        final (hit, exclude) = await _activeHead(track);
        if (hit != null) {
          appLog('ext: 「${track.title}」由当前音源出链（${hit.tag}）');
          return [hit];
        }
        skip = {...skip, ...exclude};
      } else {
        final id = store.activeSettings?.lxScript ?? '';
        if (id.isNotEmpty) skip = {...skip, id};
      }
      final hits =
          await _urlFromScripts(
        track,
        _lxQualityCandidates(),
        skip,
        maxHits: 5,
      ).timeout(const Duration(seconds: 20), onTimeout: () {
        appLog('ext: 平台曲目直取 20s 用尽');
        return const [];
      });
      return hits;
    } catch (error) {
      appLog('ext: 平台曲目直取失败: $error');
      return const [];
    }
  }

  /// 选定脚本（settings.lxScript，仅 lx 模式）独占出链：等待就绪 +
  /// 逐档 musicUrl。对齐 lx-music-desktop 的「音源即脚本」——选定脚本
  /// 不是并发池里的一员，而是音源本身。
  ///
  /// 返回 null = 无有效选定脚本（未选/不存在），调用方走聚合；
  /// 抛 String = 选定脚本存在但本次失败（消息点名脚本与原因，并点亮
  /// 会话内熔断）。
  static Future<LxHit?> _urlFromActiveScript(
    Track track,
    List<String> qualityCandidates,
  ) async {
    final id = store.activeSettings?.lxScript ?? '';
    if (id.isEmpty) return null;
    final script = LxRuntime.instance.scriptById(id);
    if (script == null) return null;
    String fail(String reason) {
      _activeHeadFuse = reason;
      _activeHeadFuseId = id;
      return '当前音源「${script.name}」$reason';
    }
    if (!script.ready) {
      if (script.error.isNotEmpty) {
        throw fail('初始化失败：${script.error}');
      }
      // 等它就绪：loadScript 带 loading 去重（进行中立即返回），之后
      // 轮询状态直至就绪/失败/期限。
      unawaited(LxRuntime.instance.loadScript(id));
      final deadline = DateTime.now().add(const Duration(seconds: 18));
      while (!script.ready &&
          script.error.isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (!script.ready) {
        throw fail(
          '初始化未完成（${script.error.isEmpty ? "超时" : script.error}）',
        );
      }
    }
    final qualitys = script.sources[track.platform];
    if (qualitys == null || qualitys.isEmpty) {
      throw fail('不支持${track.platformLabel}平台'
          '（声明支持 ${script.sources.keys.join("/")}）');
    }
    final stopwatch = Stopwatch()..start();
    for (final quality in qualityCandidates) {
      if (!qualitys.contains(quality)) continue;
      String? url;
      try {
        url = await LxRuntime.instance
            .musicUrl(
              id,
              track.platform,
              track.songmid,
              quality,
              name: track.title,
              singer: track.artist,
            )
            .timeout(const Duration(seconds: 8));
      } catch (error) {
        speedStore.update(
          lxSpeedKey(id),
          const SpeedResult(ms: 0, text: '出链超时', ok: false),
        );
        throw fail('出链超时/失败（$quality）：$error');
      }
      if (url != null) {
        speedStore.update(
          lxSpeedKey(id),
          SpeedResult(
            ms: stopwatch.elapsedMilliseconds,
            text: '可用',
            ok: true,
          ),
        );
        return (
          url: url,
          label: '外部·${script.name} $quality',
          tag: '$id-$quality',
          scriptId: id,
        );
      }
    }
    speedStore.update(
      lxSpeedKey(id),
      const SpeedResult(ms: 0, text: '出链失败', ok: false),
    );
    throw fail('未能出链（尝试档位 ${qualityCandidates.join("/")}）');
  }

  /// 选定脚本首攻编排：hit = 独占命中（调用方整链返回）；exclude =
  /// 首攻已试过（含熔断）的脚本 id，聚合链据此排除。停用/隐藏的脚本
  /// 视为「选择失效」，等同未选（对齐 lx-music 删除当前源后回落）。
  static Future<(LxHit?, Set<String>)> _activeHead(Track track) async {
    final settings = store.activeSettings;
    final id = settings?.lxScript ?? '';
    if (settings?.sourceMode != 'lx' || id.isEmpty) return (null, const <String>{});
    if ((settings?.lxDisabledScripts ?? const <String>[]).contains(id) ||
        (settings?.lxHiddenScripts ?? const <String>[]).contains(id)) {
      return (null, const <String>{});
    }
    if (_activeHeadFuse != null && _activeHeadFuseId == id) {
      appLog('ext: 当前音源首攻熔断中（$_activeHeadFuse），本次跳过');
      return (null, {id});
    }
    if (LxRuntime.instance.scriptById(id) == null) return (null, const <String>{});
    try {
      final hit = await _urlFromActiveScript(track, _lxQualityCandidates());
      if (hit != null) {
        _activeHeadFuse = null;
        return (hit, const <String>{});
      }
    } catch (error) {
      appLog('ext: $error（回落其余通道）');
    }
    return (null, {id});
  }

  /// 复位选定脚本首攻熔断：切换脚本、脚本重载/更新/测速成功后调用，
  /// 恢复「选定脚本独占首攻」。
  static void resetActiveScriptFuse() {
    _activeHeadFuse = null;
    _activeHeadFuseId = '';
  }

  /// 用户停用 + 隐藏的脚本集合（解析链跳过）。
  static Set<String> _lxSkipSet() => {
        ...?store.activeSettings?.lxDisabledScripts,
        ...?store.activeSettings?.lxHiddenScripts,
      };

  /// 并发对就绪脚本出链（songmid → URL），收集到 [maxHits] 个命中为止。
  /// name/singer 透传给脚本（部分脚本按歌名+歌手在平台内自搜）。
  /// 多候选供下载层回退：个别脚本的直链会被 CDN 拒（HTTP 403 等），
  /// 单候选时只能整曲失败跳歌。
  ///
  /// 这是聚合兜底链（选定脚本首攻失败后/未选定脚本/汽水试听回落）：
  /// 选定脚本若有效且已就绪，仍排在队首优先出链（default 模式回落链
  /// 的偏好语义）；其余按测速延迟排序。
  ///
  /// 脚本间并发（先命中先收）：串行遍历时一个死/慢脚本就能吃光整个
  /// 预算——源已死的僵尸脚本每次出链挂到内部 25s 超时，慢而活的源
  /// （中转链 >5s）也挡住后面，可用脚本永远轮不到。并发下死源各自
  /// 超时互不拖累，慢源在预算内自己完成。
  static Future<
      List<({String url, String label, String tag, String scriptId})>
    > _urlFromScripts(
    Track track,
    List<String> qualityCandidates,
    Set<String> skip, {
    int maxHits = 1,
  }) async {
    final platform = track.platform;
    final songmid = track.songmid;
    final hits = <({String url, String label, String tag, String scriptId})>[];
    final activeId = store.activeSettings?.lxScript ?? '';
    // 其余脚本按测速延迟升序（测过的可用脚本优先出链——测速的排序
    // 价值直接传导到解析链；未测/异常的垫底，跨源多样性仍在）。
    int speedOf(LxScriptInfo script) {
      final result = speedStore.of(lxSpeedKey(script.id));
      return result != null && result.ok ? result.ms : 1 << 30;
    }

    final others = [
      for (final script in LxRuntime.instance.scripts)
        if (script.id != activeId) script,
    ]..sort((a, b) => speedOf(a).compareTo(speedOf(b)));
    final ordered = [
      for (final script in LxRuntime.instance.scripts)
        if (script.id == activeId) script,
      ...others,
    ];
    final targets = <LxScriptInfo>[];
    for (final script in ordered) {
      if (skip.contains(script.id)) continue; // 用户停用/隐藏的脚本
      if (script.error.isNotEmpty && !script.ready) continue; // 已知死源
      if (!script.ready) {
        // 解析链不等懒加载：单脚本冷启动可到 15s，等它必把 12s/20s 的
        // 解析预算烧穿（脚本未就绪期切歌全部回落汽水）。预热交给
        // warmUp 与这里的后台触发（loadScript 自带 loading 去重），
        // 出链只用已就绪脚本。
        unawaited(LxRuntime.instance.loadScript(script.id));
        continue;
      }
      final qualitys = script.sources[platform];
      if (qualitys == null || qualitys.isEmpty) continue;
      targets.add(script);
    }
    final queue = List.of(targets);
    // WebView 内 JS 调度串行、网络等待异步：4 路并发是安全水位
    Future<void> worker() async {
      while (queue.isNotEmpty && hits.length < maxHits) {
        final script = queue.removeAt(0);
        final qualitys = script.sources[platform]!;
        for (final quality in qualityCandidates) {
          if (hits.length >= maxHits) return;
          if (!qualitys.contains(quality)) continue;
          // 单脚本单档 8s 上限（实测 oiapi 类中转源 5-16s 才回有效直链，
          // 5s 会误杀；超时/异常视为该脚本已死，跳过它的剩余档位。
          String? url;
          try {
            url = await LxRuntime.instance
                .musicUrl(
                  script.id,
                  platform,
                  songmid,
                  quality,
                  name: track.title,
                  singer: track.artist,
                )
                .timeout(const Duration(seconds: 8));
          } catch (error) {
            appLog('ext: 出链[${script.id}] 超时/失败(8s pass): $error');
            // 会话内降权：出链都拿不到 URL 的脚本（当前平台通道死）即刻
            // 踢出可用组——否则同一批死源在每首歌上都从头撞一遍超时
            // （用户看到「跳过好几个音源才播出」的主要拖慢来源）。
            speedStore.update(
              lxSpeedKey(script.id),
              const SpeedResult(ms: 0, text: '出链超时', ok: false),
            );
            break;
          }
          if (url != null) {
            hits.add((
              url: url,
              label: '外部·${script.name} $quality',
              tag: '${script.id}-$quality',
              scriptId: script.id,
            ));
            break; // 该脚本已出一个候选，换下一脚本（跨源更稳）
          }
          // url == null：脚本活着但该档位没拿到，继续试下一档位
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    return hits;
  }

  static Future<List<LxHit>> _resolveExtViaLx(
    Track track,
    List<String> qualityCandidates,
    List<String> disabled,
    List<String> hidden, {
    int maxHits = 1,
  }) async {
    final skip = {...disabled, ...hidden};
    // 两个平台搜索并发发出（匹配仍按 wy → kw 优先级取第一个命中），
    // 省掉一次串行搜索往返。
    final songmids = await Future.wait(
      ['wy', 'kw'].map((platform) => _searchAndMatch(platform, track)),
    );
    for (final (index, platform) in ['wy', 'kw'].indexed) {
      final songmid = songmids[index];
      if (songmid == null) continue;
      final matched = Track(
        id: '${platform}_$songmid',
        title: track.title,
        artist: track.artist,
        album: track.album,
        platform: platform,
      );
      // lx 模式下选定脚本仍独占首攻（音源即脚本），失败聚合排除它。
      final (headHit, headExclude) = await _activeHead(matched);
      if (headHit != null) {
        appLog('ext: 搜索匹配 [$platform] 命中「${track.title}」'
            '（当前音源出链）');
        return [headHit];
      }
      final hits = await _urlFromScripts(
        matched,
        qualityCandidates,
        {...skip, ...headExclude},
        maxHits: maxHits,
      );
      if (hits.isNotEmpty) {
        appLog('ext: 搜索匹配 [$platform] 命中「${track.title}」'
            '（${hits.length} 个候选）');
        return hits;
      }
    }
    return const [];
  }

  /// 平台搜索 + 标题/歌手/时长匹配 → songmid。
  static Future<String?> _searchAndMatch(String platform, Track track) async {
    try {
      final keyword = '${track.title} ${track.artist}'.trim();
      final data = await _call('searchPlatform', {
        'platform': platform,
        'keyword': keyword,
      });
      final results = (data['results'] as List? ?? const [])
          .whereType<Map>()
          .toList(growable: false);
      String norm(String text) =>
          text.toLowerCase().replaceAll(RegExp(r'\s'), '');
      String? best;
      var bestScore = -1;
      for (final result in results) {
        final title = result['title']?.toString() ?? '';
        final artist = result['artist']?.toString() ?? '';
        final duration =
            int.tryParse(result['durationSeconds'].toString()) ?? 0;
        final ta = norm(track.title);
        final tb = norm(title);
        if (ta.isEmpty || tb.isEmpty) continue;
        int score;
        if (ta == tb) {
          score = 10;
        } else if (tb.contains(ta) || ta.contains(tb)) {
          score = 5;
        } else {
          continue;
        }
        final aa = norm(track.artist);
        final ab = norm(artist);
        if (aa.isNotEmpty) {
          if (ab.contains(aa) || aa.contains(ab)) {
            score += 6;
          } else {
            score -= 3;
          }
        }
        if (duration > 0) {
          final diff = (track.durationSeconds - duration).abs();
          if (diff <= 3) {
            score += 4;
          } else if (diff <= 8) {
            score += 2;
          } else if (diff > 30) {
            score -= 2;
          }
        }
        if (score >= 8 && score > bestScore) {
          bestScore = score;
          best = result['songmid']?.toString();
        }
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  /// 直链下载失败的脚本踢出测速「可用」组（出链排序即刻降权）。
  static void _demoteDeadScript(String scriptId) {
    if (scriptId.isEmpty) return;
    speedStore.update(
      lxSpeedKey(scriptId),
      const SpeedResult(ms: 0, text: '直链不可达', ok: false),
    );
  }

  /// 直链可达性探测（测速端到端验证用）：Range 取前 1KB，3s 上限。
  /// 出链成功但 CDN 已死（DNS 失败/403）的脚本不配「可用」——否则按
  /// 延迟排序抢先进解析链，把点歌拖进换源循环。
  static Future<bool> probeMediaUrl(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 3));
      request.headers.set(HttpHeaders.userAgentHeader, kDirectUrlUA);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final response = await request.close().timeout(
            const Duration(seconds: 3),
          );
      await response.drain<void>().timeout(const Duration(seconds: 2));
      return response.statusCode == 200 || response.statusCode == 206;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 外部直链下载到缓存（Dart HttpClient；命名 {id}-ext-lx-{tag}.{ext}）。
  static Future<String?> _downloadExt(
    String url,
    Track track,
    String tag,
  ) async {
    try {
      final ext = Uri.parse(url).path.toLowerCase().endsWith('.flac')
          ? 'flac'
          : Uri.parse(url).path.toLowerCase().endsWith('.m4a')
          ? 'm4a'
          : 'mp3';
      final dir = Directory('${await store.Settings.resolveCacheDir()}/tracks');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}/${track.id}-ext-lx-$tag.$ext');
      if (file.existsSync() && file.lengthSync() > 64 * 1024) {
        return file.path; // 之前已缓存
      }
      // 共享 client（连接复用）：多候选换源重试时不再逐次重开连接。
      final client = sharedHttpClient;
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, kDirectUrlUA);
      final response = await request.close();
      if (response.statusCode != 200) {
        appLog('ext: 直链下载 HTTP ${response.statusCode}');
        return null;
      }
      // 传输整体预算 60s：connectionTimeout 只管建连，直链服务器
      // 慢速/停滞吐流时 pipe 会无限等（实测播放页「下载/解密中」
      // 永久转圈的根因）——超时即取消、删半截文件、回落汽水。
      final sink = file.openWrite();
      final done = Completer<void>();
      late final StreamSubscription<List<int>> subscription;
      subscription = response.listen(
        sink.add,
        onError: (Object error) {
          if (!done.isCompleted) done.completeError(error);
        },
        onDone: () async {
          try {
            await sink.close();
            if (!done.isCompleted) done.complete();
          } catch (error) {
            if (!done.isCompleted) done.completeError(error);
          }
        },
        cancelOnError: true,
      );
      try {
        await done.future.timeout(const Duration(seconds: 60));
      } catch (error) {
        await subscription.cancel();
        try {
          await sink.close();
        } catch (_) {}
        if (file.existsSync()) file.deleteSync();
        appLog('ext: 直链下载失败/超时: $error');
        return null;
      }
      if (file.lengthSync() <= 64 * 1024) {
        // 过小视为无效（防假直链/错误页）
        file.deleteSync();
        appLog('ext: 直链内容过小（${file.lengthSync()}B）弃用');
        return null;
      }
      return file.path;
    } catch (error) {
      appLog('ext: 直链下载失败: $error');
      return null;
    }
  }

  /// 平台搜索（wy/kw）：返回 [{songmid, title, artist, durationSeconds}]。
  static Future<List<Map<String, dynamic>>> searchPlatform(
    String platform,
    String keyword, {
    int page = 1,
  }) async {
    final data = await _call('searchPlatform', {
      'platform': platform,
      'keyword': keyword,
      'page': page,
    });
    return (data['results'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
  }

  /// 平台曲目搜索（LX 模式曲库）：结果直接构造为一等 [Track]
  /// （id 命名空间 `kw_123`/`wy_456`，可播放、可进最近播放/喜欢）。
  /// hasMore = 满页（Rust 侧按页大小判定）。
  static Future<({List<Track> tracks, bool hasMore})> platformTracks(
    String platform,
    String keyword, {
    int page = 1,
  }) async {
    final results = await searchPlatform(platform, keyword, page: page);
    return _platformResultTracks(platform, results);
  }

  /// 平台榜单曲目（kg/wy/tx 免签真榜单；kw 的 chartId 即搜索关键词，
  /// 见 lx_catalog 的 lxCatalogFor）。与 [platformTracks] 同形态。
  static Future<({List<Track> tracks, bool hasMore})> chartTracks(
    String platform,
    String chartId, {
    int page = 1,
  }) async {
    final data = await _call('chartTracks', {
      'platform': platform,
      'chartId': chartId,
      'page': page,
    });
    final results = (data['results'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
    return _platformResultTracks(platform, results);
  }

  /// 平台原始结果（{songmid, title, artist, durationSeconds}）→ Track。
  static ({List<Track> tracks, bool hasMore}) _platformResultTracks(
    String platform,
    List<Map<String, dynamic>> results,
  ) =>
      (
        tracks: results
            .map((item) => Track(
                  id: '${platform}_${item['songmid'] ?? ''}',
                  title: item['title']?.toString() ?? '',
                  artist: item['artist']?.toString() ?? '',
                  album: '',
                  durationSeconds:
                      int.tryParse(item['durationSeconds'].toString()) ?? 0,
                  platform: platform,
                ))
            .where((track) =>
                track.songmid.isNotEmpty && track.title.isNotEmpty)
            .toList(growable: false),
        hasMore: results.length >= 30,
      );

  /// 音质限免链路诊断：签名服务测速（POST /sign 最小请求）。
  /// 返回延迟毫秒与可读结果（可用 / 鉴权失败 / 网络失败）。
  static Future<({int ms, String result})> signerPing(
    String url,
    String token,
  ) async {
    final target = url.trim();
    if (target.isEmpty) return (ms: 0, result: '未配置服务地址');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final stopwatch = Stopwatch()..start();
    try {
      final request = await client.postUrl(Uri.parse(target));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      final tokenText = token.trim();
      if (tokenText.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $tokenText',
        );
      }
      // 请求形状必须与 Rust 侧真实取流一致：应用签名覆盖「URL+请求头」，
      // 缺 headers 字段时签名引擎拿不到头，必然回「只拿到 0 个头」502。
      request.write(
        '{"url":"https://api.qishui.com/luna/pc/track_v2?aid=386088",'
        '"method":"POST","body":"{}","ts_ms":'
        '${DateTime.now().millisecondsSinceEpoch},'
        '"headers":{"user-agent":"LunaPC/3.3.0(359450208)"}}',
      );
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      final ms = stopwatch.elapsedMilliseconds;
      // 先看回包内容再回退状态码：网关 5xx 时服务端常仍带回真实原因
      // （如「签名不完整：只拿到 0 个头」），只报 HTTP 502 会误导排查方向。
      final value = jsonDecodeOrNull(body);
      if (value is Map && value['ok'] == false) {
        final code = value['code']?.toString() ?? '';
        final message = value['error']?.toString() ?? '服务返回失败';
        if (code.toLowerCase() == 'unauthorized' ||
            message.toLowerCase().contains('unauthorized')) {
          return (ms: ms, result: '令牌无效或缺失（unauthorized）');
        }
        final statusSuffix =
            response.statusCode == 200 ? '' : '（HTTP ${response.statusCode}）';
        return (ms: ms, result: '$message$statusSuffix');
      }
      if (response.statusCode == 401) {
        return (ms: ms, result: '服务要求鉴权（HTTP 401）：请填写访问令牌');
      }
      if (response.statusCode != 200) {
        return (ms: ms, result: 'HTTP ${response.statusCode}');
      }
      return (ms: ms, result: '可用（$ms ms）');
    } catch (error) {
      return (ms: stopwatch.elapsedMilliseconds, result: '连接失败：$error');
    } finally {
      client.close(force: true);
    }
  }

  static dynamic jsonDecodeOrNull(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static Future<CacheStats> cacheStats() async =>
      CacheStats.fromJson(await _call('cacheStats'));

  /// 清空音频缓存（Rust 清文件）并同步清掉索引。
  static Future<void> clearCache() async {
    await _call('clearCache');
    await CacheIndex.clear();
  }
}
