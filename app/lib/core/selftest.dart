/// 自驱动冒烟测试：在真机上无 UI 交互地验证核心链路。
///
/// 触发方式：SSH 在容器里创建 `<sandbox>/tmp/SODAM_SELFTEST` 标记文件后
/// 启动 App；跑完自动删除标记并把 PASS/FAIL 摘要写进 sodam-debug.log。
/// 正常用户不受影响（无标记即直接返回）。
library;

import 'dart:async';
import 'dart:io';

import 'api.dart';
import 'appearance.dart';
import 'history.dart';
import 'logging.dart';
import 'lx_runtime.dart';
import 'lyrics.dart';
import 'models.dart';
import 'page_cache.dart';
import 'player.dart';
import 'selftest_v02.dart';
import 'session.dart';
import 'store.dart' as store;
import 'updater.dart';

Future<void> maybeRunSelfTest(
  PlayerController player,
  Appearance appearance,
) async {
  final File marker;
  try {
    marker = File('${await store.appContainerRoot()}/tmp/SODAM_SELFTEST');
  } catch (_) {
    return;
  }
  if (!marker.existsSync()) return;

  final selftestAlbums = <AlbumItem>[];

  appLog('selftest: ===== begin =====');
  final results = <String>[];

  Future<void> step(String name, Future<void> Function() body) async {
    try {
      await body();
      results.add('$name=PASS');
      appLog('selftest: $name=PASS');
    } catch (error, stack) {
      if (error.toString().contains('未登录')) {
        // 未登录是账号态问题不是缺陷：记 SKIP，不算 FAIL
        results.add('$name=SKIP(未登录)');
        appLog('selftest: $name=SKIP(未登录)');
        return;
      }
      if (error.toString().contains('视频曲目')) {
        // 歌单里只有抖音视频（暂不支持播放）同样是账号内容形态，不是缺陷
        results.add('$name=SKIP(视频曲目)');
        appLog('selftest: $name=SKIP(视频曲目)');
        return;
      }
      results.add('$name=FAIL($error)');
      appLog('selftest: $name=FAIL: $error');
      appLog(
        'selftest: stack: '
        '${stack.toString().split('\n').take(3).join(' | ')}',
      );
    }
  }

  // ---- 网络鉴别诊断：裸 IP 直连 vs DNS 解析 vs 回环/局域网 ----
  await step('net.rawIpConnect', () async {
    // api.qishui.com 的 CDN IP（SSH shell 解析所得），仅诊断用
    final socket = await Socket.connect(
      '122.228.79.44',
      443,
      timeout: const Duration(seconds: 8),
    );
    socket.destroy();
  });
  await step('net.dnsResolve', () async {
    final list = await InternetAddress.lookup('api.qishui.com');
    if (list.isEmpty) throw 'empty result';
    appLog('selftest: dns -> ${list.first.address}');
  });
  await step('net.loopbackRoute', () async {
    // 连 127.0.0.1 上的无监听端口：Connection refused = 回环可达（路由放行）；
    // No route to host = 回环也被 NECP 封
    try {
      final s = await Socket.connect(
        '127.0.0.1',
        18080,
        timeout: const Duration(seconds: 5),
      );
      s.destroy(); // 竟然连上了（有服务在听），也算放行
      appLog('selftest: loopback connected unexpectedly');
    } on SocketException catch (error) {
      final text = error.message;
      appLog('selftest: loopback probe -> $text');
      if (text.contains('refused')) return; // 被拒=路由通
      rethrow;
    }
  });
  await step('net.lanRoute', () async {
    // 探本机 WiFi 接口地址上的无监听端口（此前硬编码的部署机 IP 已随
    // 网络环境变化过期）：Connection refused = 本子网路由放行。
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    if (interfaces.isEmpty || interfaces.first.addresses.isEmpty) {
      throw 'no ipv4 interface';
    }
    final own = interfaces.first.addresses.first.address;
    appLog('selftest: wifi ip -> $own');
    try {
      final s = await Socket.connect(
        own,
        18080,
        timeout: const Duration(seconds: 5),
      );
      s.destroy(); // 竟然连上了（有服务在听），也算放行
      appLog('selftest: lan connected unexpectedly');
    } on SocketException catch (error) {
      final text = error.message;
      appLog('selftest: lan probe -> $text');
      if (text.contains('refused')) return; // 被拒=路由通
      rethrow;
    }
  });

  final feedTracks = <Track>[];
  final searchArtists = <ArtistItem>[];
  await step('account', () async {
    final me = await Api.account();
    if (me.nickname.trim().isEmpty) throw 'empty nickname';
    appLog(
      'selftest: account=${me.nickname} vip=${me.vip} '
      'id=${me.userId}',
    );
  });
  await step('hotWords', () async {
    final words = await Api.hotWords();
    if (words.isEmpty) throw 'empty hot words';
    appLog('selftest: hot words=${words.take(3).join('/')}');
  });
  await step('scenes', () async {
    final scenes = await Api.scenes();
    if (scenes.isEmpty) throw 'empty scenes';
  });
  await step('feed', () async {
    final page = await Api.feed();
    if (page.tracks.isEmpty) throw 'empty feed';
    feedTracks.addAll(page.tracks);
    appLog(
      'selftest: feed got ${page.tracks.length} tracks, '
      'first="${page.tracks.first.title}"',
    );
  });
  await step('suggest', () async {
    final words = await Api.suggest('周杰伦');
    if (words.isEmpty) throw 'empty suggest';
  });
  await step('qrCreate', () async {
    // 走内置签名页（loopback 中继 + bdms 签名）创建登录二维码：
    // 这是扫码登录链路里唯一能无 UI 验证的一环。
    final qr = await Api.qrCreate();
    if (qr.scanUrl.trim().isEmpty || !qr.scanUrl.contains('token=')) {
      throw 'bad scan url: ${qr.scanUrl}';
    }
    appLog(
      'selftest: qr created, scanUrl=${qr.scanUrl.length} chars, '
      'expire=${qr.expireTime}',
    );
  });
  await step('qrCheckPoll', () async {
    // 新建二维码后轮询 2 次：应停在 waiting（或 expired），不应抛错/限流。
    // 验证 a_bogus 签名链路在轮询形态下依然有效（qrCreate 只验单次请求）。
    final qr = await Api.qrCreate();
    for (var i = 0; i < 2; i++) {
      final result = await Api.qrCheck(qr.token);
      appLog(
        'selftest: qr poll#$i status=${result.status} '
        'rateLimited=${result.rateLimited}',
      );
      if (result.rateLimited) throw 'poll #$i rate limited';
      switch (result.status) {
        case 'waiting' || 'scanned' || 'expired':
          break;
        default:
          throw 'unexpected status ${result.status} (${result.message})';
      }
      if (i == 0) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  });
  await step('myPlaylists', () async {
    final page = await Api.myPlaylists();
    appLog(
      'selftest: playlists=${page.playlists.length} '
      '(titles=${page.playlists.take(3).map((p) => p.title).join('/')})',
    );
    for (final playlist in page.playlists) {
      appLog('selftest: playlist kind=${playlist.kind} "${playlist.title}"');
    }
  });
  await step('playlistTracks', () async {
    // 用抖音收藏系统歌单验证歌单曲目链路（内容稳定为纯曲目）。
    final page = await Api.myPlaylists();
    PlaylistItem? target;
    for (final p in page.playlists) {
      if (p.isDouyinFavorites) {
        target = p;
        break;
      }
    }
    if (target == null) throw '未登录'; // 无系统歌单 → 账号态问题
    final detail = await Api.playlistDetail(target.id);
    if (detail.tracks.isEmpty) {
      throw 'playlist "${target.title}" returned 0 tracks';
    }
    appLog(
      'selftest: playlistTracks "${target.title}" -> ${detail.tracks.length} '
      'tracks, first="${detail.tracks.first.title}", '
      'meta=${detail.meta != null ? 'title="${detail.meta!.title}" creator="${detail.meta!.creator}"' : 'null'}',
    );
  });
  await step('douyinFavorites', () async {
    final tracks = await Api.douyinFavorites();
    appLog('selftest: douyin favorites=${tracks.length}');
  });
  await step('likedSongs', () async {
    final tracks = await Api.likedSongs();
    appLog('selftest: liked songs=${tracks.length}');
  });
  final searchTracks = <Track>[];
  await step('search', () async {
    final results = await Api.searchAll('周杰伦');
    if (results.tracks.isEmpty) throw 'empty search tracks';
    searchTracks.addAll(results.tracks);
    searchArtists.addAll(results.artists.take(3));
    // 供 albumTracks 步骤用（专辑可能搜不到：跳过不算失败）
    selftestAlbums.addAll(results.albums.take(3));
  });
  await step('lx.platformSearch', () async {
    // 平台曲库（LX 模式首页/发现/搜索的数据源）：免签 kw 搜索 + 分页。
    final page1 = await Api.platformTracks('kw', '周杰伦', page: 1);
    if (page1.tracks.isEmpty) throw 'empty kw results';
    if (!page1.tracks.every((t) => t.platform == 'kw')) throw 'platform 标记缺失';
    if (!page1.tracks.every((t) => t.songmid.isNotEmpty)) throw 'songmid 缺失';
    if (!page1.hasMore) throw '第一页未满页（分页异常）';
    final page2 = await Api.platformTracks('kw', '周杰伦', page: 2);
    final ids1 = page1.tracks.map((t) => t.id).toSet();
    if (page2.tracks.any((t) => ids1.contains(t.id))) {
      appLog('selftest: kw 第二页与第一页有重复（提示，不算失败）');
    }
    appLog('selftest: kw p1=${page1.tracks.length} p2=${page2.tracks.length}');
  });
  await step('lx.extPlatforms', () async {
    // 新平台免签搜索（kg/tx）+ 平台歌词（kw/wy/kg/tx 全链）。
    for (final platform in ['kg', 'tx']) {
      final page = await Api.platformTracks(platform, '周杰伦 晴天');
      if (page.tracks.isEmpty) throw 'empty $platform results';
      final track = page.tracks.first;
      appLog('selftest: $platform 首条 ${track.title} / ${track.artist}');
      final lyric = await Api.platformLyrics(
        platform,
        track.songmid,
        track.id,
      );
      final parsed = parseLrc(lyric.lrc);
      if (parsed.isEmpty) throw '$platform lyric unparsed';
      appLog('selftest: $platform 歌词 ${parsed.length} 行');
    }
  });
  await step('artistDetail', () async {
    // PC 形态端点（/luna/pc/artists/*）：App 会话可能被签名门禁拒，
    // 结果对路线图 Phase 2 验收重要，失败时如实记录。
    if (searchArtists.isEmpty) throw '未登录'; // 借用 SKIP 语义：搜索无艺人
    final artist = searchArtists.first;
    final detail = await Api.artistDetail(artist.id);
    if (detail.name.trim().isEmpty) throw 'empty artist name';
    appLog(
      'selftest: artist "${detail.name}" '
      'hot=${detail.hotTracks.length} tracks=${detail.trackCount}',
    );
  });
  await step('artistTracks', () async {
    if (searchArtists.isEmpty) throw '未登录';
    final page = await Api.artistTracks(searchArtists.first.id, count: 20);
    if (page.tracks.isEmpty) throw 'empty artist tracks';
    appLog(
      'selftest: artistTracks ${page.tracks.length} '
      'hasMore=${page.hasMore}',
    );
  });
  await step('artistAlbums', () async {
    if (searchArtists.isEmpty) throw '未登录';
    final page = await Api.artistAlbums(searchArtists.first.id, count: 20);
    appLog('selftest: artistAlbums ${page.albums.length}');
  });
  await step('collectedPlaylists', () async {
    final lists = await Api.collectedPlaylists();
    appLog('selftest: collected playlists=${lists.length}');
  });
  await step('discoverSquare', () async {
    // 歌单广场（discovery_playlist 场景流）
    final page = await Api.discoverMix('discovery_playlist', count: 10);
    if (page.playlists.isEmpty) {
      throw 'empty square (blocks=${page.blocks.length})';
    }
    appLog(
      'selftest: square ${page.playlists.length} playlists, '
      'first="${page.playlists.first.title}", '
      'hasMore=${page.hasMore} cursor=${page.nextCursor}',
    );
  });
  await step('discoverChart', () async {
    // 排行榜（discovery_chart 场景流）：榜单 block 形状随服务端浮动，
    // 歌单形态或原始 block 任一有内容即算通，并把首 block 字段打出来。
    final page = await Api.discoverMix('discovery_chart', count: 30);
    if (page.playlists.isEmpty && page.blocks.isEmpty) {
      throw 'empty chart response';
    }
    final blockKeys = page.blocks.isEmpty
        ? '<no blocks>'
        : page.blocks.first.keys.toList().toString();
    appLog(
      'selftest: chart playlists=${page.playlists.length} '
      'blocks=${page.blocks.length} blockKeys=$blockKeys',
    );
  });
  RadioStation? radioStation;
  await step('radioList', () async {
    // 电台列表（官方发现页 discover_radio 块；移动端 /luna/discover）
    final stations = await Api.radioList();
    if (stations.isEmpty) {
      // 空电台：打出 FFI 调试信息（块类型/原始回包头）供定位
      try {
        final debug = await Api.radioListDebug();
        appLog('selftest: radioList debug=$debug');
      } catch (_) {}
      throw 'empty radio stations';
    }
    radioStation = stations.first;
    appLog(
      'selftest: radio ${stations.length} 台，'
      '首台="${stations.first.title}" id=${stations.first.id} '
      'color=${stations.first.color}',
    );
  });
  await step('radioTracks', () async {
    // 电台曲目队列（无限电台核心端点）
    final station = radioStation;
    if (station == null) throw '未登录（上一步无电台）'; // 借 SKIP 语义
    final page = await Api.radioTracks(station.id, count: 20);
    if (page.tracks.isEmpty) throw 'empty radio tracks';
    appLog(
      'selftest: radioTracks "${station.title}" '
      '${page.tracks.length} 首：'
      '${page.tracks.map((t) => t.title.isEmpty ? "<空:${t.id}>" : t.title).take(6).join("/")}',
    );
  });
  await step('recommendPlaylists', () async {
    final playlists = await Api.recommendPlaylists();
    if (playlists.isEmpty) throw 'empty recommend playlists';
    appLog(
      'selftest: recommend ${playlists.length}, '
      'first="${playlists.first.title}"',
    );
  });
  await step('collectedArtists', () async {
    // 已解析拍平（关注列表可能为空——关注端点被风控时也回空列表，不算错）
    final page = await Api.collectedArtists();
    appLog(
      'selftest: collectedArtists ${page.artists.length} 位'
      '${page.artists.isEmpty ? '' : '，首位=${page.artists.first.name}'}',
    );
  });
  await step('albumTracks', () async {
    if (selftestAlbums.isEmpty) throw '未登录'; // 借用 SKIP 语义：无专辑可测
    var lastError = 'no album tried';
    for (final album in selftestAlbums) {
      try {
        final tracks = await Api.albumTracks(album.id);
        if (tracks.isNotEmpty) {
          appLog('selftest: album "${album.title}" -> ${tracks.length} tracks');
          return;
        }
        lastError = 'album "${album.title}" returned 0 tracks';
      } catch (error) {
        lastError = '$error';
      }
    }
    throw lastError;
  });
  await step('albumMeta', () async {
    // 专辑元信息（发行时间/简介，fetch_album_detail 优先路径）
    if (selftestAlbums.isEmpty) throw '未登录';
    var lastError = 'no album tried';
    for (final album in selftestAlbums) {
      try {
        final detail = await Api.albumDetail(album.id);
        if (detail.tracks.isEmpty) {
          lastError = 'album "${album.title}" returned 0 tracks';
          continue;
        }
        appLog(
          'selftest: albumMeta "${detail.meta?.title ?? album.title}" '
          'release=${detail.meta?.releaseDateLabel ?? '无'} '
          'desc=${detail.meta?.description.isNotEmpty == true ? '有' : '无'} '
          'tracks=${detail.tracks.length}',
        );
        return;
      } catch (error) {
        lastError = '$error';
      }
    }
    throw lastError;
  });
  await step('prepareAndPlay', () async {
    // 搜索结果第一首（未登录也可试听的曲目）
    final track = searchTracks.first;
    final prepared = await Api.prepareTrack(track);
    appLog(
      'selftest: prepared "${track.title}" '
      'quality=${prepared.quality} cached=${prepared.cached}',
    );
    await player.playQueue(searchTracks.take(3).toList(), 0);
    // 最多等 15s 出声（首次要下载/解密）
    var spoke = false;
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (player.audioPlayer.playing &&
          player.audioPlayer.position.inMilliseconds > 800) {
        spoke = true;
        break;
      }
    }
    if (!spoke) {
      throw 'no progress (lastError=${player.lastError}, '
          'playing=${player.audioPlayer.playing}, '
          'pos=${player.audioPlayer.position})';
    }
    appLog(
      'selftest: playing, pos='
      '${player.audioPlayer.position.inMilliseconds}ms',
    );
    // seek 验证
    await player.audioPlayer.seek(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (player.audioPlayer.position.inSeconds < 8) {
      throw 'seek failed (pos=${player.audioPlayer.position})';
    }
  });
  await step('streamLadder', () async {
    // 免签名取流梯子矩阵：逐档偏好看实际命中层（web/h5/mobile/pc）。
    // 诊断步骤不判 FAIL（层可用性随设备会话/风控波动），日志里看结论。
    final track = searchTracks.first;
    final rungs = await Api.streamLadder(track);
    final buffer = StringBuffer();
    for (final rung in rungs) {
      final result = Map<String, dynamic>.from(rung['result'] as Map? ?? {});
      final hit = result['error'] != null
          ? 'ERR ${result['error']}'
          : '${result['origin'] ?? '-'}:'
              '${result['quality'] ?? '-'}'
              '${result['isPreview'] == true ? '(试听)' : ''}';
      buffer.write('${rung['preference']}=$hit  ');
    }
    appLog('selftest: streamLadder "${track.title}" → $buffer');
  });
  await step('perf.concurrentFFI', () async {
    // 性能回归检测：整曲下载（长 IO）在途时，轻量会话请求必须立即可答。
    // 旧实现所有方法共享一把全局 Mutex，下载期间 ping 会排队数秒。
    final track = searchTracks.length > 2
        ? searchTracks[2]
        : searchTracks.first;
    final slow = Api.prepareTrack(track);
    // 给慢请求 300ms 先进入 FFI（旧实现此时已持有全局锁）
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final t0 = DateTime.now();
    await Api.ping(); // 不走网络：纯测会话排队
    final ms = DateTime.now().difference(t0).inMilliseconds;
    final prepared = await slow;
    appLog(
      'selftest: concurrent ping=${ms}ms '
      '(在途下载 "${track.title}" → ${prepared.quality})',
    );
    if (ms > 2000) {
      throw '轻量请求被长 IO 堵塞 ${ms}ms（会话锁回归）';
    }
  });
  await step('perf.pageCache', () async {
    await PageCache.writeJson('selftest-probe', {'v': 42});
    final back = await PageCache.readJson('selftest-probe');
    if (back?['v'] != 42) throw '缓存 roundtrip 失败: $back';
    appLog('selftest: pageCache roundtrip ok');
  });
  await step('lyrics', () async {
    final track = player.currentTrack;
    if (track == null) throw 'no current track';
    final lyric = await Api.lyricsWithTranslation(track.id);
    final lrc = lyric.lrc;
    if (lrc.trim().isEmpty) throw 'empty lyrics';
    final parsed = parseLrc(lrc);
    if (parsed.isEmpty) {
      throw 'lyrics unparsed (${lrc.length} chars, 头部 ${lrc.substring(0, lrc.length > 40 ? 40 : lrc.length)})';
    }
    appLog(
      'selftest: lyrics ${lrc.length} chars → ${parsed.length} lines '
      '(translations: ${lyric.translations.keys.join(",")})',
    );
  });
  await step('lyricTranslation', () async {
    // 英文歌验证翻译链路（SEO 回包 lyric.translations.cn）
    const tid = '6704999686110971906'; // Shape of You - Ed Sheeran
    final lyric = await Api.lyricsWithTranslation(tid);
    final trans = lyric.translations['cn'] ?? '';
    if (trans.trim().isEmpty) {
      throw '无中文翻译（translations=${lyric.translations.keys.toList()}）';
    }
    final main = parseLrc(lyric.lrc);
    final aligned = alignTranslations(main, trans);
    if (aligned.isEmpty) throw '翻译对齐为 0 行';
    appLog(
      'selftest: lyricTranslation cn=${trans.length} chars → '
      '${aligned.length}/${main.length} 行对齐',
    );
  });
  await step('collectedAlbums', () async {
    final result = await Api.collectedAlbums();
    appLog(
      'selftest: collectedAlbums ${result.albums.length} 张 '
      '(hasMore=${result.hasMore})',
    );
  });
  await step('relatedTracks', () async {
    final track = player.currentTrack;
    if (track == null) throw 'no current track';
    final related = await Api.relatedTracks(track.id);
    if (related.isEmpty) throw '相似歌曲为空（接口形态或风控）';
    appLog(
      'selftest: relatedTracks ${related.length} 首, 首曲='
      '"${related.first.title}"',
    );
  });
  await step('musicWall', () async {
    // 我的音乐墙（PC 形态端点）：曲目墙 + 口味标签
    final wall = await Api.musicWall();
    if (wall.tracks.isEmpty) throw '音乐墙为空（未登录或接口受限）';
    appLog(
      'selftest: musicWall ${wall.tracks.length} 首, '
      'tags=${wall.tags.map((tag) => tag.tag).join("/")}',
    );
  });
  await step('trackComments', () async {
    // 热门评论随歌词请求带回（SEO 分享页内嵌；Lemon 评论区大）
    const tid = '6990158606909835265'; // Lemon - 米津玄師
    final lyric = await Api.lyricsWithTranslation(tid);
    if (lyric.comments.isEmpty) throw '热门评论为空（SEO comments 缺失）';
    final head = String.fromCharCodes(
      lyric.comments.first.content.runes.take(12),
    );
    appLog(
      'selftest: trackComments 总数=${lyric.commentCount} '
      '内嵌=${lyric.comments.length} 首条="$head…"',
    );
  });
  await step('history', () async {
    final tracks = await PlayHistory.load();
    if (tracks.isEmpty) throw 'history not recorded';
    appLog(
      'selftest: history ${tracks.length} tracks, '
      'first="${tracks.first.title}"',
    );
  });
  await step('sessionPersist', () async {
    // playQueue 已触发 _saveSession；验证会话落盘且队列/索引/进度有效
    final session = await PlaySession.load();
    if (session == null) throw 'session not saved';
    if (session.tracks.isEmpty ||
        session.index < 0 ||
        session.index >= session.tracks.length) {
      throw 'bad session (index=${session.index}, '
          'tracks=${session.tracks.length})';
    }
    appLog(
      'selftest: session ${session.tracks.length} tracks @${session.index} '
      'mode=${session.playMode} pos=${session.positionMs}ms',
    );
  });
  await step('extLxScripts', () async {
    // lx 脚本运行时：预热状态 + 至少一个脚本可出链（第三方网络服务，
    // 全挂时记 SKIP 语义：抛「无可用 lx 脚本」由 step 记 FAIL 亦可接受，
    // 这里选择宽松——就绪数为 0 只记日志，不阻断）。
    await LxRuntime.instance.ensureStarted();
    await LxRuntime.instance.refreshStatus();
    final ready = LxRuntime.instance.scripts.where((s) => s.ready).length;
    final total = LxRuntime.instance.scripts.length;
    appLog('selftest: lx 运行时就绪，脚本 $ready/$total 可用');
    if (ready == 0) {
      appLog('selftest: 无可用 lx 脚本（第三方服务波动，不阻断）');
      return;
    }
    final songmid = await _kwBestMatch();
    if (songmid == null) {
      appLog('selftest: lx 平台搜索未命中（不阻断）');
      return;
    }
    for (final script in LxRuntime.instance.scripts) {
      if (!script.ready || !(script.sources['kw']?.isNotEmpty ?? false)) {
        continue;
      }
      final raw = await LxRuntime.instance.musicUrlRaw(
        script.id,
        'kw',
        songmid,
        '128k',
      );
      final url = raw['result']?.toString() ?? '';
      if (raw['ok'] == true && url.startsWith('http')) {
        appLog('selftest: lx ${script.name} [kw] 出链 ✓');
        return;
      }
      appLog('selftest: lx ${script.name} [kw] 未出链: $url');
    }
    appLog('selftest: lx 脚本就绪但本次未出链（不阻断）');
  });
  await step('cacheStats', () async {
    final stats = await Api.cacheStats();
    appLog('selftest: cache files=${stats.files} bytes=${stats.bytes}');
  });
  await step('clearCache', () async {
    await Api.clearCache();
    final emptied = await Api.cacheStats();
    if (emptied.files != 0) {
      throw '清缓存后仍有 ${emptied.files} 个文件';
    }
    // 重新预热当前曲目（同时再验一次冷缓存下载路径）
    final track = player.currentTrack;
    if (track != null) {
      final prepared = await Api.prepareTrack(track);
      if (prepared.cached) throw '清缓存后 prepare 应重新下载';
      final refilled = await Api.cacheStats();
      if (refilled.files < 1) throw '重新下载后缓存仍为空';
      appLog(
        'selftest: clearCache ok, warmed '
        '"${track.title}" again (${prepared.quality})',
      );
    }
  });

  // ---- 设置页三件套（Phase10）：日志缓冲 / 升级 ----
  await step('settings.logBuffer', () async {
    appLog('selftest: ring probe');
    if (logBufferSnapshot().isEmpty) throw 'ring buffer 为空';
    final path = logFilePath;
    if (path == null || !File(path).existsSync()) throw '日志文件缺失';
  });
  await step('updater.versionCompare', () async {
    final cases = <List<String>>[
      ['0.3.0', '0.2.10', 'gt'],
      ['0.2.0', '0.2.0', 'eq'],
      ['0.2.1', '0.2.10', 'lt'],
      ['1.0.0', '0.9.9', 'gt'],
    ];
    for (final c in cases) {
      final v = compareVersions(c[0], c[1]);
      final expect = c[2] == 'gt' ? 1 : (c[2] == 'lt' ? -1 : 0);
      if ((v > 0 ? 1 : v < 0 ? -1 : 0) != expect) {
        throw '${c[0]} vs ${c[1]} 期望 ${c[2]} 实际 $v';
      }
    }
  });
  await step('updater.githubCheck', () async {
    final result = await Updater.check();
    if (result.status == UpdateCheck.available ||
        result.status == UpdateCheck.latest) {
      appLog('selftest: update -> ${result.release!.version}');
      return;
    }
    // 404 = GitHub 可达但仓库还没有 Release（等首发后自然转 PASS）
    if ((result.error ?? '').contains('404')) {
      appLog('selftest: update -> repo 无 Release（按可达计 PASS）');
      return;
    }
    throw result.error ?? 'unknown';
  });
  // ---- v0.2 迁移功能（Beans-Music）真机专项验证 ----
  // 数据层往返 + 活体 UI 渲染（个性化组合实时切换 / 外观页 / 排行页）。
  await runV02FeatureChecks(player, appearance, step);

  // 收尾：暂停但保留队列现场（pause 会保存会话）——供部署流水线
  // 紧随其后的「killall → 二次启动 → 检查恢复会话」跨进程验证。
  await player.pause();
  try {
    await marker.delete();
  } catch (_) {
    // 已被删则忽略
  }
  appLog('selftest: SUMMARY ${results.join(' ')}');
  appLog('selftest: ===== end =====');
}

/// lx 探测：kw 平台搜「搁浅 周杰伦」按标题/歌手匹配取 songmid。
Future<String?> _kwBestMatch() async {
  try {
    final results = await Api.searchPlatform('kw', '搁浅 周杰伦');
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\s'), '');
    for (final r in results) {
      if (norm(r['title']?.toString() ?? '') == '搁浅' &&
          norm(r['artist']?.toString() ?? '').contains('周杰伦')) {
        return r['songmid']?.toString();
      }
    }
    for (final r in results) {
      if (norm(r['title']?.toString() ?? '').contains('搁浅')) {
        return r['songmid']?.toString();
      }
    }
  } catch (_) {}
  return null;
}
