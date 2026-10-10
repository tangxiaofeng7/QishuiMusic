/// 数据模型（与 Rust FFI 的 JSON 键一一对应，camelCase）。

library;

import 'dart:ui' show Color;

/// 把 FFI 返回的 JSON 数组解析为模型列表。
List<T> parseList<T>(dynamic raw, T Function(Map<String, dynamic>) fromJson) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map<String, dynamic>>()
      .map(fromJson)
      .toList(growable: false);
}

/// 宽松取整数：num 直接用，字符串数字（"61"）也收，其余回退。
int _flexInt(dynamic value, [int fallback = 0]) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

/// 解析曲目列表（多个 API 共用）。
List<Track> parseTracks(dynamic raw) => parseList(raw, Track.fromJson);

/// 平台曲目 id 前缀（`kw_123` / `wy_456` …）→ 平台标识；无前缀返回 ''。
String platformFromIdPrefix(String id) {
  for (final prefix in const ['kw', 'wy', 'kg', 'tx']) {
    if (id.startsWith('${prefix}_')) return prefix;
  }
  return '';
}

class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    this.artistId = '',
    this.albumId = '',
    this.cover = '',
    this.durationSeconds = 0,
    this.vip = false,
    this.platform = '',
    this.cachedPath = '',
    this.cachedQuality = '',
  });

  factory Track.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final platform = json['platform']?.toString() ?? '';
    return Track(
      id: id,
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
      album: json['album']?.toString() ?? '',
      artistId: json['artistId']?.toString() ?? '',
      albumId: json['albumId']?.toString() ?? '',
      cover: json['cover']?.toString() ?? '',
      durationSeconds: _flexInt(json['durationSeconds']),
      vip: json['vip'] == true,
      // 旧版本持久化的平台曲目只有 `kw_123` 形态的 id、没有 platform
      // 字段（最近播放/喜欢/会话恢复都有存量）：丢失平台会让点播走错
      // 解析链（汽水侧查无此曲 → 回落试听/报错），从 id 前缀补回。
      platform:
          platform.isNotEmpty ? platform : platformFromIdPrefix(id),
      cachedPath: json['cachedPath']?.toString() ?? '',
      cachedQuality: json['cachedQuality']?.toString() ?? '',
    );
  }

  final String id;
  final String title;
  final String artist;
  final String album;
  final String artistId;
  final String albumId;
  final String cover;
  final int durationSeconds;
  final bool vip;

  /// 曲目来源平台：'' = 汽水（默认，账号曲库）；'kw'/'wy' = 平台曲目
  /// （酷我/网易云，id 形如 `kw_12345`，由平台搜索结果构造）。
  /// 平台曲目的播放走 lx 脚本链（songmid 直取，不经过汽水）。
  final String platform;

  /// 平台曲目的原始 songmid（剥掉 id 里的平台前缀）；汽水曲目即 id 本身。
  String get songmid =>
      platform.isEmpty || !id.startsWith('${platform}_')
          ? id
          : id.substring(platform.length + 1);

  /// 已验证存在的本地整曲文件（「已缓存曲目」点播/会话恢复时携带）：
  /// 非空时播放链路直接放本地文件，零网络探测。
  final String cachedPath;

  /// [cachedPath] 对应文件的音质标签（如「flac」「外部·独家LX 320k」）。
  final String cachedQuality;

  /// 仅覆盖缓存直通字段的副本（音质重载时清掉直通标记用）。
  Track copyWithCache({String? cachedPath, String? cachedQuality}) => Track(
        id: id,
        title: title,
        artist: artist,
        album: album,
        artistId: artistId,
        albumId: albumId,
        cover: cover,
        durationSeconds: durationSeconds,
        vip: vip,
        platform: platform,
        cachedPath: cachedPath ?? this.cachedPath,
        cachedQuality: cachedQuality ?? this.cachedQuality,
      );

  /// 平台显示名（曲目行/播放页的小标签用）。
  String get platformLabel => switch (platform) {
        'kw' => '酷我',
        'wy' => '网易云',
        'kg' => '酷狗',
        'tx' => 'QQ音乐',
        _ => '',
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'artistId': artistId,
        'albumId': albumId,
        'cover': cover,
        'durationSeconds': durationSeconds,
        'vip': vip,
        'platform': platform,
        'cachedPath': cachedPath,
        'cachedQuality': cachedQuality,
      };

  String get durationLabel {
    if (durationSeconds <= 0) return '--:--';
    final minutes = durationSeconds ~/ 60;
    final seconds = durationSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

/// 电台（官方「汽水FM」风格电台站，来自发现页 discover_radio 块）。
class RadioStation {
  const RadioStation({
    required this.id,
    required this.title,
    this.desc = '',
    this.cover = '',
    this.color = '',
  });

  factory RadioStation.fromJson(Map<String, dynamic> json) => RadioStation(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        desc: json['desc']?.toString() ?? '',
        cover: json['cover']?.toString() ?? '',
        color: json['color']?.toString() ?? '',
      );

  final String id;
  final String title;
  final String desc;
  final String cover;

  /// 服务端给的封面主色（形如 `328693` 的六位 hex，无 # 前缀）。
  final String color;

  /// 主色转 Flutter Color；非法值（空/长度不为 6）给 null，UI 回落主题色。
  Color? get dominantColor {
    final hex = color.trim();
    if (hex.length != 6) return null;
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return null;
    return Color(0xFF000000 | value);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'desc': desc,
        'cover': cover,
        'color': color,
      };
}

class ArtistItem {
  const ArtistItem({
    required this.id,
    required this.name,
    this.avatar = '',
    this.trackCount = 0,
    this.followerCount = 0,
  });

  factory ArtistItem.fromJson(Map<String, dynamic> json) => ArtistItem(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        avatar: json['avatar']?.toString() ?? '',
        trackCount: _flexInt(json['trackCount']),
        followerCount: _flexInt(json['followerCount']),
      );

  final String id;
  final String name;
  final String avatar;
  final int trackCount;
  final int followerCount;
}

/// 音乐墙口味标签（服务端下发配色，形如 `1E7C39` / 透明度 `66`）。
class MusicWallTag {
  const MusicWallTag({required this.tag, this.rgb = '', this.alpha = ''});

  factory MusicWallTag.fromJson(Map<String, dynamic> json) => MusicWallTag(
        tag: json['tag']?.toString() ?? '',
        rgb: json['rgb']?.toString() ?? '',
        alpha: json['alpha']?.toString() ?? '',
      );

  final String tag;
  final String rgb;
  final String alpha;

  /// 服务端配色；非法值（空/长度不为 6）给 null，UI 回落主题色。
  Color? get color {
    final hex = rgb.trim();
    if (hex.length != 6) return null;
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return null;
    final alphaValue = int.tryParse(alpha.trim(), radix: 16);
    final opacity =
        alphaValue == null ? 1.0 : (alphaValue / 255).clamp(0.0, 1.0);
    return Color(0xFF000000 | value).withValues(alpha: opacity);
  }
}

/// 曲目热门评论（SEO 分享页内嵌，只读）。
class TrackComment {
  const TrackComment({
    required this.id,
    required this.content,
    this.nickname = '',
    this.avatar = '',
    this.ipLabel = '',
    this.likes = 0,
    this.replies = 0,
    this.time = 0,
    this.featured = false,
  });

  factory TrackComment.fromJson(Map<String, dynamic> json) => TrackComment(
        id: json['id']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        nickname: json['nickname']?.toString() ?? '',
        avatar: json['avatar']?.toString() ?? '',
        ipLabel: json['ipLabel']?.toString() ?? '',
        likes: _flexInt(json['likes']),
        replies: _flexInt(json['replies']),
        time: _flexInt(json['time']),
        featured: json['featured'] == true,
      );

  final String id;
  final String content;
  final String nickname;
  final String avatar;
  final String ipLabel;
  final int likes;
  final int replies;
  final int time;
  final bool featured;

  /// 评论时间的简短展示（当年省年份，跨年带年份）。
  String get timeLabel {
    if (time <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(time * 1000);
    final now = DateTime.now();
    final monthDay = '${date.month}月${date.day}日';
    return date.year == now.year ? monthDay : '${date.year}年$monthDay';
  }
}

class AlbumItem {
  const AlbumItem({
    required this.id,
    required this.title,
    this.cover = '',
    this.artist = '',
    this.trackCount = 0,
  });

  factory AlbumItem.fromJson(Map<String, dynamic> json) => AlbumItem(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        cover: json['cover']?.toString() ?? '',
        artist: json['artist']?.toString() ?? '',
        trackCount: _flexInt(json['trackCount']),
      );

  final String id;
  final String title;
  final String cover;
  final String artist;
  final int trackCount;
}

class PlaylistItem {
  const PlaylistItem({
    required this.id,
    required this.title,
    this.cover = '',
    this.trackCount = 0,
    this.creator = '',
    this.kind = 0,
  });

  factory PlaylistItem.fromJson(Map<String, dynamic> json) => PlaylistItem(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        cover: json['cover']?.toString() ?? '',
        trackCount: _flexInt(json['trackCount']),
        creator: json['creator']?.toString() ?? '',
        kind: _flexInt(json['kind']),
      );

  final String id;
  final String title;
  final String cover;
  final int trackCount;
  final String creator;

  /// 官方系统歌单类型：1=我喜欢的音乐、4=抖音收藏的音乐。
  final int kind;

  /// 系统歌单判定：kind + 官方固定标题双判。
  /// （移动端 /luna/me/playlist 部分账号 type 缺失回 0；PC 回落恒 0。）
  bool get isLiked => kind == 1 || title.trim() == '我喜欢的音乐';
  bool get isDouyinFavorites =>
      kind == 4 || title.trim() == '抖音收藏的音乐';

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'cover': cover,
        'trackCount': trackCount,
        'creator': creator,
        'kind': kind,
      };
}

/// 歌单详情元数据（/luna/playlist/detail 首屏回包附带）。
class PlaylistMeta {
  const PlaylistMeta({
    required this.id,
    required this.title,
    this.desc = '',
    this.cover = '',
    this.trackCount = 0,
    this.playCount = 0,
    this.collectedCount = 0,
    this.creator = '',
    this.isPrivate = false,
  });

  factory PlaylistMeta.fromJson(Map<String, dynamic> json) => PlaylistMeta(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        desc: json['desc']?.toString() ?? '',
        cover: json['cover']?.toString() ?? '',
        trackCount: _flexInt(json['trackCount']),
        playCount: _flexInt(json['playCount']),
        collectedCount: _flexInt(json['collectedCount']),
        creator: json['creator']?.toString() ?? '',
        isPrivate: json['isPrivate'] == true,
      );

  final String id;
  final String title;
  final String desc;
  final String cover;
  final int trackCount;
  final int playCount;
  final int collectedCount;
  final String creator;
  final bool isPrivate;
}

/// 艺人详情（头像/简介统计 + 热门歌曲）。
class ArtistDetail {
  const ArtistDetail({
    required this.id,
    required this.name,
    this.avatar = '',
    this.trackCount = 0,
    this.followerCount = 0,
    this.hotTracks = const [],
  });

  factory ArtistDetail.fromJson(Map<String, dynamic> json) => ArtistDetail(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        avatar: json['avatar']?.toString() ?? '',
        trackCount: _flexInt(json['trackCount']),
        followerCount: _flexInt(json['followerCount']),
        hotTracks: parseTracks(json['hotTracks']),
      );

  final String id;
  final String name;
  final String avatar;
  final int trackCount;
  final int followerCount;
  final List<Track> hotTracks;
}

class SearchResults {
  const SearchResults({
    required this.tracks,
    required this.artists,
    required this.albums,
    required this.playlists,
  });

  factory SearchResults.fromJson(Map<String, dynamic> json) => SearchResults(
        tracks: parseTracks(json['tracks']),
        artists: parseList(json['artists'], ArtistItem.fromJson),
        albums: parseList(json['albums'], AlbumItem.fromJson),
        playlists: parseList(json['playlists'], PlaylistItem.fromJson),
      );

  final List<Track> tracks;
  final List<ArtistItem> artists;
  final List<AlbumItem> albums;
  final List<PlaylistItem> playlists;
}

class SceneItem {
  const SceneItem({
    required this.text,
    required this.entryType,
    required this.sceneModeId,
    required this.subQueueType,
    this.cover = '',
  });

  factory SceneItem.fromJson(Map<String, dynamic> json) => SceneItem(
        text: json['text']?.toString() ?? '',
        entryType: json['entryType']?.toString() ?? '',
        sceneModeId: _flexInt(json['sceneModeId'], -1),
        subQueueType: json['subQueueType']?.toString() ?? '',
        cover: json['cover']?.toString() ?? '',
      );

  final String text;
  final String entryType;
  final int sceneModeId;
  final String subQueueType;
  final String cover;

  Map<String, dynamic> toJson() => {
        'text': text,
        'entryType': entryType,
        'sceneModeId': sceneModeId,
        'subQueueType': subQueueType,
        'cover': cover,
      };
}

class FeedPage {
  const FeedPage({
    required this.tracks,
    required this.hasMore,
    required this.fetchCounter,
    required this.didFirstUseTime,
  });

  factory FeedPage.fromJson(Map<String, dynamic> json) => FeedPage(
        tracks: parseTracks(json['tracks']),
        hasMore: json['hasMore'] == true,
        fetchCounter: _flexInt(json['fetchCounter']),
        didFirstUseTime: _flexInt(json['didFirstUseTime']),
      );

  final List<Track> tracks;
  final bool hasMore;
  final int fetchCounter;
  final int didFirstUseTime;
}

class AccountInfo {
  const AccountInfo({
    required this.nickname,
    required this.userId,
    required this.vip,
    this.avatarUrl = '',
  });

  factory AccountInfo.fromJson(Map<String, dynamic> json) => AccountInfo(
        nickname: json['nickname']?.toString() ?? '',
        userId: json['userId']?.toString() ?? '',
        vip: json['vip'] == true,
        avatarUrl: json['avatarUrl']?.toString() ?? '',
      );

  final String nickname;
  final String userId;
  final bool vip;
  final String avatarUrl;

  Map<String, dynamic> toJson() => {
        'nickname': nickname,
        'userId': userId,
        'vip': vip,
        'avatarUrl': avatarUrl,
      };
}

class QrLoginResult {
  const QrLoginResult({
    required this.status,
    required this.message,
    this.cookie = '',
    this.needSecondVerify = false,
    this.rateLimited = false,
    this.extra = const {},
  });

  factory QrLoginResult.fromJson(Map<String, dynamic> json) => QrLoginResult(
        status: json['status']?.toString() ?? 'waiting',
        message: json['message']?.toString() ?? '',
        cookie: json['cookie']?.toString() ?? '',
        needSecondVerify: json['needSecondVerify'] == true,
        rateLimited: json['rateLimited'] == true,
        extra: (json['extra'] as Map?)?.cast<String, String>() ?? const {},
      );

  final String status;
  final String message;
  final String cookie;
  final bool needSecondVerify;
  final bool rateLimited;

  /// Rust 侧透传的诊断信息（error_code / api_status / description 等）。
  final Map<String, String> extra;
}

class PreparedTrack {
  const PreparedTrack({
    required this.path,
    required this.quality,
    required this.cached,
    this.origin = '',
    this.layer = '',
    this.url = '',
    this.ua = '',
    this.sizeBytes,
  });

  factory PreparedTrack.fromJson(Map<String, dynamic> json) => PreparedTrack(
        path: json['path']?.toString() ?? '',
        quality: json['quality']?.toString() ?? '',
        cached: json['cached'] == true,
        layer: json['origin']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
        ua: json['ua']?.toString() ?? '',
        sizeBytes: (json['size'] as num?)?.toInt(),
      );

  final String path;
  final String quality;
  final bool cached;

  /// 实际取流来源（如「其他音源-独家LX」「汽水账号」）。
  /// Dart 侧分流时写入：音源展示以实际为准，而不是设置里的音源模式。
  final String origin;

  /// Rust 取流梯子的命中层（web / h5 / mobile / pc，空 = 缓存命中或外部链）。
  /// h5 / mobile 是「免签名直取」层：无签名服务时的高音质通道。
  final String layer;

  /// 免签层明文流的 CDN 直链：非空 = 交播放器流式播放（不整曲下载落盘）。
  final String url;

  /// 流式播放需携带的 User-Agent（与 Rust 侧下载器一致，CDN 可能校验）。
  final String ua;

  /// 当前档位音频的大小（字节）：Rust 回包透出（缓存命中=文件实际大小、
  /// 流式=服务端 Size、落盘=写入字节）；外部链在 Dart 侧读文件补齐。
  /// null = 未知（不展示）。
  final int? sizeBytes;

  /// 是否走流式直链（url 非空即流式）。
  bool get streaming => url.isNotEmpty;
}

class CacheStats {
  const CacheStats({required this.bytes, required this.files});

  factory CacheStats.fromJson(Map<String, dynamic> json) => CacheStats(
        bytes: _flexInt(json['bytes']),
        files: _flexInt(json['files']),
      );

  final int bytes;
  final int files;
}

/// 发现页内容流（discover/mix：歌单广场 / 排行榜 / 电台）。
///
/// 同时携带类型化拍平的歌单列表与原始回包：歌单形态直接用 [playlists]，
/// 榜单等其它 block 形态从 [blocks] 里按需挖（字段随服务端版本浮动）。
class DiscoverPage {
  const DiscoverPage({
    required this.playlists,
    required this.hasMore,
    required this.nextCursor,
    required this.blocks,
  });

  factory DiscoverPage.fromJson(Map<String, dynamic> json) {
    final raw = json['raw'];
    final rawMap = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return DiscoverPage(
      playlists: parseList(json['playlists'], PlaylistItem.fromJson),
      hasMore: json['hasMore'] == true,
      nextCursor: rawMap['cursor']?.toString() ?? json['cursor']?.toString() ?? '',
      blocks: (rawMap['inner_block'] as List? ?? const [])
          .whereType<Map>()
          .map((block) => Map<String, dynamic>.from(block))
          .toList(growable: false),
    );
  }

  final List<PlaylistItem> playlists;

  /// 分页：原始回包里的游标（服务端有则翻页，无则只有一页）。
  final bool hasMore;
  final String nextCursor;

  /// 原始 `inner_block[]`（榜单标题等扩展字段从这里取）。
  final List<Map<String, dynamic>> blocks;
}

/// 排行榜条目：一个榜单（本质是特殊歌单）+ 榜单名。
class ChartEntry {
  const ChartEntry({required this.title, required this.playlist});

  final String title;
  final PlaylistItem playlist;

  /// 从 discover/mix 原始 block 提取（block 字段名随版本浮动，多候选兜底）。
  static ChartEntry? fromBlock(Map<String, dynamic> block) {
    String title = '';
    for (final key in ['title', 'name', 'block_title']) {
      final value = block[key]?.toString() ?? '';
      if (value.trim().isNotEmpty) {
        title = value.trim();
        break;
      }
    }
    final resources = (block['resources'] as List? ?? const [])
        .whereType<Map>()
        .map((resource) => Map<String, dynamic>.from(resource))
        .toList(growable: false);
    for (final resource in resources) {
      final entity = resource['entity'];
      if (entity is! Map) continue;
      final playlist = entity['playlist'];
      if (playlist is Map) {
        final item =
            _playlistFromDiscoverRaw(Map<String, dynamic>.from(playlist));
        if (item.id.isNotEmpty) {
          return ChartEntry(
            title: title.isEmpty ? item.title : title,
            playlist: item,
          );
        }
      }
    }
    return null;
  }

  /// discover/mix 原始歌单实体的字段名与归一化口径不同
  /// （封面在 `url_cover{urls,uri,template_prefix}`、曲目数是 `count_tracks`、
  /// 展示标题优先 `public_title`），不能直接走 [PlaylistItem.fromJson]。
  static PlaylistItem _playlistFromDiscoverRaw(Map<String, dynamic> raw) {
    final publicTitle = raw['public_title']?.toString().trim() ?? '';
    return PlaylistItem(
      id: raw['id']?.toString() ?? '',
      title: publicTitle.isNotEmpty
          ? publicTitle
          : raw['title']?.toString() ?? '',
      cover: _discoverCoverUrl(raw['url_cover']),
      trackCount: _flexInt(raw['count_tracks']),
    );
  }

  /// 封面完整地址：服务端只回 `urls` 前缀 + `uri`（或 uri + template_prefix
  /// 模板形态）。拼接规则镜像 libresoda `sodaBuildImageURL`（types.rs），
  /// 改一处需同步另一处。
  static String _discoverCoverUrl(dynamic image) {
    if (image is! Map) return '';
    final urls = ((image['urls'] as List?) ?? const [])
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList();
    final uri = image['uri']?.toString().trim() ?? '';
    final prefix = image['template_prefix']?.toString().trim() ?? '';
    if (uri.isNotEmpty && prefix.isNotEmpty) {
      return 'https://p3-luna.douyinpic.com/img/$uri~$prefix-resize:960:960.png';
    }
    var cover = urls.isEmpty ? '' : urls.first;
    if (uri.isNotEmpty && !cover.contains(uri)) cover += uri;
    return cover;
  }

  factory ChartEntry.fromCache(Map<String, dynamic> json) => ChartEntry(
        title: json['title']?.toString() ?? '',
        playlist:
            PlaylistItem.fromJson(Map<String, dynamic>.from(json['playlist'])),
      );

  Map<String, dynamic> toCache() => {'title': title, 'playlist': playlist.toJson()};
}

/// 专辑元信息（公开分享页解析附带）。
class AlbumMeta {
  const AlbumMeta({
    required this.title,
    this.artist = '',
    this.cover = '',
    this.trackCount = 0,
    this.releaseDateMs = 0,
    this.description = '',
  });

  factory AlbumMeta.fromJson(Map<String, dynamic> json) {
    // release_date 可能是毫秒或秒级时间戳
    var release = _flexInt(json['releaseDate']);
    if (release > 0 && release < 10000000000) release *= 1000;
    return AlbumMeta(
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
      cover: json['cover']?.toString() ?? '',
      trackCount: _flexInt(json['trackCount']),
      releaseDateMs: release,
      description: json['description']?.toString() ?? '',
    );
  }

  final String title;
  final String artist;
  final String cover;
  final int trackCount;
  final int releaseDateMs;
  final String description;

  String? get releaseDateLabel {
    if (releaseDateMs <= 0) return null;
    final date = DateTime.fromMillisecondsSinceEpoch(releaseDateMs);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
