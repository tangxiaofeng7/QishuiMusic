/// 播放控制器：just_audio 播放本地解密文件，audio_service 提供后台播放
/// 与锁屏/控制中心控制。

library;

import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'api.dart';
import 'history.dart';
import 'logging.dart';
import 'models.dart';
import 'play_stats.dart';
import 'radio.dart';
import 'session.dart';
import 'source.dart';
import 'store.dart' as store;
import '../ui/widgets/cover.dart';

enum PlayMode { sequence, repeatOne, shuffle }

extension PlayModeLabel on PlayMode {
  String get label => switch (this) {
        PlayMode.sequence => '列表循环',
        PlayMode.repeatOne => '单曲循环',
        PlayMode.shuffle => '随机播放',
      };
}

/// 既是 audio_service 的 AudioHandler（锁屏控制），又是 ChangeNotifier
/// （UI 监听当前曲目/准备状态/音质变化）。
class PlayerController extends BaseAudioHandler with ChangeNotifier {
  PlayerController() {
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        // completed 事件会重复：到点 pause() 在 completed 态下再发一次
        // (playing=false, completed)，不闩上会把「播完即停」误当续播
        // （2026-10-09 真机日志实证：生效 2ms 后当前曲被重载续播）
        if (_completionHandled) return;
        _completionHandled = true;
        if (sleepAfterCurrent) {
          // 睡眠定时「播完当前这首」：当前曲播完即停，不续播
          sleepAfterCurrent = false;
          appLog('player: 播完当前曲，睡眠定时生效（不续播）');
          unawaited(_onSleepReached());
          return;
        }
        unawaited(skipToNext());
      } else {
        _completionHandled = false;
      }
    });
    // 切换播放音源后当前曲换源重载：不重载的话当前曲会一直播旧源的
    // 流，切到酷我后播放页仍是汽水音源（2026-10-10 用户反馈）。mode
    // 变化影响所有曲目；lx 模式内切脚本对平台曲目同样是换解析通道
    // （选定脚本独占首攻），也要重载。
    _lastSourceMode = sourceStore.mode;
    _lastSourceScript = sourceStore.script;
    sourceStore.addListener(_onSourceModeChanged);
    appLog('player: controller created');
  }

  String? _lastSourceMode;
  String? _lastSourceScript;

  void _onSourceModeChanged() {
    final mode = sourceStore.mode;
    final script = sourceStore.script;
    final modeChanged = mode != _lastSourceMode;
    // 平台曲目（kw_/wy_…）在 lx 模式下由选定脚本独占首攻：换脚本 =
    // 换音源；汽水曲目的取流路径只随 mode 变（试听回落链只是兜底，
    // 不随脚本收敛）。
    final scriptChanged = mode == 'lx' &&
        script != _lastSourceScript &&
        (currentTrack?.platform.isNotEmpty ?? false);
    _lastSourceMode = mode;
    _lastSourceScript = script;
    if (!modeChanged && !scriptChanged) return;
    if (currentTrack == null || restoring) return;
    appLog('player: 音源切换为 $mode'
        '${scriptChanged ? '（脚本 → $script）' : ''}，'
        '当前曲换源重载 "${currentTrack!.title}"');
    // 空闲时走无缝重载（旧流继续播，新源就绪即接管）；准备中则作为
    // 一次普通加载重来（在途结果按新音源作废，UI 如实转圈）
    unawaited(_load(sourceReload: preparingTrack.value == null));
  }

  /// 单曲准备（探测 + 下载）总预算：链路各环节（Rust 探测 12s/端点、
  /// 外部直链 60s、lx 链 12s……）叠加后仍可能拖到分钟级，超时兜底报错
  /// 并自动跳下一首，杜绝播放页无限转圈。
  static const _prepareBudget = Duration(seconds: 90);

  final AudioPlayer _player = AudioPlayer();
  final List<Track> _tracks = [];
  final Random _random = Random();

  /// 当前加载任务序号：快速切歌时丢弃过期结果（对齐桌面端的竞态守卫）。
  int _loadSeq = 0;
  int _index = -1;
  PlayMode playMode = PlayMode.sequence;
  String? lastError;
  String currentQuality = '';

  /// 当前曲实际取流来源（音源展示以实际为准；空 = 尚未加载）。
  String currentSourceLabel = '';

  /// 当前档位音频大小（字节，null = 未知）——音质面板「当前音源」行展示。
  int? currentSizeBytes;

  // ---- 电台（官方「无限电台」）：会话存在即电台模式 ----
  RadioSession? _radio;

  /// 当前电台会话（null = 普通队列模式）。
  RadioSession? get radio => _radio;

  bool get radioActive => _radio != null;

  /// 会话恢复后待跳转的进度（非空 = 恢复态：尚未加载音频，
  /// 点播放时才会下载并 seek 到该位置）。
  int? _restoredPositionMs;

  // ---- 睡眠定时器：到点暂停（保留队列与进度，不做清场）----
  Timer? _sleepTimer;
  DateTime? _sleepDeadline;

  /// completed 事件闩锁：同一曲的播完只处理一次（离开 completed 即复位）。
  bool _completionHandled = false;

  /// 「播完当前这首再停」模式（当前曲播完不再续播）。
  bool sleepAfterCurrent = false;

  /// 剩余秒数（无活动定时返回 null；播完即停模式返回 -1）。
  int? get sleepRemainingSeconds {
    if (sleepAfterCurrent) return -1;
    return _sleepDeadline?.difference(DateTime.now()).inSeconds;
  }

  bool get sleepActive => sleepAfterCurrent || _sleepDeadline != null;

  /// 设置睡眠定时：[minutes] > 0 定时暂停，0 = 播完当前这首，null = 取消。
  void setSleepTimer({int? minutes}) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
    sleepAfterCurrent = false;
    if (minutes != null && minutes > 0) {
      _sleepDeadline = DateTime.now().add(Duration(minutes: minutes));
      _sleepTimer = Timer(Duration(minutes: minutes), _onSleepReached);
      appLog('player: 睡眠定时 $minutes分钟');
    } else if (minutes == 0) {
      sleepAfterCurrent = true;
      appLog('player: 睡眠定时 播完当前这首');
    } else {
      appLog('player: 睡眠定时已取消');
    }
    notifyListeners();
  }

  Future<void> _onSleepReached() async {
    appLog('player: 睡眠定时到点，暂停（保留队列与进度）');
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
    sleepAfterCurrent = false;
    await _player.pause();
    if (!restoring) await _saveSession();
    notifyListeners();
  }

  final ValueNotifier<Track?> preparingTrack = ValueNotifier<Track?>(null);

  Track? get currentTrack =>
      _index >= 0 && _index < _tracks.length ? _tracks[_index] : null;

  List<Track> get trackQueue => List.unmodifiable(_tracks);

  int get index => _index;

  AudioPlayer get audioPlayer => _player;

  bool get hasCurrent => currentTrack != null;

  /// 恢复态：会话已还原但音频未加载（点播放才下载并跳到上次进度）。
  bool get restoring => _restoredPositionMs != null;

  int? get restoredPositionMs => _restoredPositionMs;

  /// 恢复上次播放会话（main 启动时调用）：队列/当前曲/模式/进度，
  /// 不下载不自动播放——用户点播放时才恢复流量与位置。
  Future<void> restoreSession() async {
    if (_tracks.isNotEmpty) return;
    final session = await PlaySession.load();
    if (session == null || session.tracks.isEmpty) return;
    playMode = PlayMode.values
        .where((mode) => mode.name == session.playMode)
        .firstOrNull ?? PlayMode.sequence;
    _tracks
      ..clear()
      ..addAll(session.tracks);
    _index = session.index;
    _restoredPositionMs = session.positionMs;
    await _syncQueueMediaItems();
    notifyListeners();
    appLog('player: 恢复上次会话 "${currentTrack?.title}" '
        '(队列 ${_tracks.length} 首, 进度 ${session.positionMs}ms)');
  }

  /// 保存当前播放现场（失败静默：会话持久化不阻断播放主流程）。
  Future<void> _saveSession({int? positionMs}) async {
    if (_tracks.isEmpty || _index < 0) return;
    try {
      await PlaySession.save(
        tracks: _tracks,
        index: _index,
        playMode: playMode.name,
        positionMs:
            positionMs ?? _restoredPositionMs ?? _player.position.inMilliseconds,
      );
    } catch (error) {
      appLog('player: 会话保存失败(忽略): $error');
    }
  }

  /// 随机模式下挑一个「不等于当前」的下标（Random，避免时间戳取模在
  /// 快速连点时停滞造成的死循环）。
  int _randomOtherIndex() {
    if (_tracks.length <= 1) return _index;
    var candidate = _random.nextInt(_tracks.length);
    while (candidate == _index) {
      candidate = _random.nextInt(_tracks.length);
    }
    return candidate;
  }

  int _nextIndex() {
    if (_tracks.isEmpty) return -1;
    switch (playMode) {
      case PlayMode.repeatOne:
        return _index;
      case PlayMode.shuffle:
        return _randomOtherIndex();
      case PlayMode.sequence:
        return (_index + 1) % _tracks.length;
    }
  }

  int _previousIndex() {
    if (_tracks.isEmpty) return -1;
    switch (playMode) {
      case PlayMode.shuffle:
        return _randomOtherIndex();
      case PlayMode.sequence:
      case PlayMode.repeatOne:
        return (_index - 1 + _tracks.length) % _tracks.length;
    }
  }

  /// 用一份队列播放指定曲目（普通队列：覆盖并结束电台模式）。
  Future<void> playQueue(List<Track> tracks, int startIndex) async {
    if (tracks.isEmpty || startIndex < 0 || startIndex >= tracks.length) {
      return;
    }
    _radio = null;
    _tracks
      ..clear()
      ..addAll(tracks);
    await _syncQueueMediaItems();
    await jumpToIndex(startIndex);
  }

  /// 插队播放：把曲目插到当前曲之后（「下一首播放」，不动其余顺序）。
  /// 队列里已有该曲则先挪位；空队列时直接整队列开播。
  Future<void> insertNext(Track track) async {
    if (track.id.isEmpty) return;
    if (_tracks.isEmpty) {
      await playQueue([track], 0);
      return;
    }
    final current = currentTrack;
    if (current != null && track.id == current.id) return;
    var insertAt = _index + 1;
    final existing = _tracks.indexWhere((item) => item.id == track.id);
    if (existing >= 0) {
      if (existing == _index) return;
      _tracks.removeAt(existing);
      if (existing < insertAt) insertAt--;
    }
    _tracks.insert(insertAt.clamp(0, _tracks.length), track);
    await _syncQueueMediaItems();
    await _saveSession();
    notifyListeners();
    appLog('player: 下一首播放 「${track.title}」');
  }

  /// 开播电台：拉首批建队列，成功即进入电台模式（余量不足自动续拉）。
  Future<void> startRadio(RadioStation station) async {
    final session = RadioSession(station);
    final first = await session.fetchMore(const {});
    if (first.isEmpty) {
      throw '「${station.title}」暂时拉不到内容，稍后再试';
    }
    _radio = session;
    appLog('radio: 开播「${station.title}」(${station.id}) 首批 ${first.length} 首');
    _tracks
      ..clear()
      ..addAll(first);
    await _syncQueueMediaItems();
    await jumpToIndex(0);
  }

  /// 结束电台（保留队列继续当普通列表播）。
  void endRadio() {
    if (_radio == null) return;
    appLog('radio: 结束「${_radio!.station.title}」');
    _radio = null;
    notifyListeners();
  }

  /// 电台模式「不喜欢当前曲」：拉黑并跳下一首。
  Future<void> radioDislikeCurrent() async {
    final session = _radio;
    final track = currentTrack;
    if (session == null || track == null) return;
    session.dislike(track.id);
    appLog('radio: 不喜欢「${track.title}」，换下一首');
    await skipToNext();
  }

  /// 电台自动续播：队列余量不足 3 首时后台追加一批。
  /// 连续 2 次追加失败后本轮放弃（避免错误风暴），切歌/重进电台再试。
  void _maybeExtendRadio() {
    final session = _radio;
    if (session == null || session.extending) return;
    if (session.extendFailures >= 2) return;
    final remaining = _tracks.length - (_index + 1);
    if (remaining >= 3 || _tracks.isEmpty) return;
    unawaited(() async {
      final batch = await session.fetchMore(_tracks.map((t) => t.id).toSet());
      if (_radio != session || batch.isEmpty) return;
      // 追加时用户可能已切到普通队列（_radio 已换人），上面已校验
      _tracks.addAll(batch);
      await _syncQueueMediaItems();
      await _saveSession();
      appLog('radio: 续播 +${batch.length} 首（队列 ${_tracks.length}）');
      notifyListeners();
    }());
  }

  Future<void> _syncQueueMediaItems() => updateQueue(_tracks
      .map((track) => MediaItem(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            artUri: track.cover.isEmpty ? null : Uri.tryParse(track.cover),
            duration: track.durationSeconds > 0
                ? Duration(seconds: track.durationSeconds)
                : null,
          ))
      .toList());

  /// 从队列移除一首（当前播放曲目不可移除）。
  Future<void> removeAt(int position) async {
    if (position < 0 || position >= _tracks.length || position == _index) {
      return;
    }
    _tracks.removeAt(position);
    if (position < _index) _index--;
    await _syncQueueMediaItems();
    await _saveSession();
    notifyListeners();
  }

  /// 清空队列并停止播放。
  Future<void> clearQueue() async {
    _loadSeq++; // 使在途加载失效
    _radio = null;
    await _player.stop();
    setSleepTimer(minutes: null); // 队列已清，睡眠定时无意义
    _tracks.clear();
    _index = -1;
    lastError = null;
    currentQuality = '';
    currentSourceLabel = '';
    currentSizeBytes = null;
    preparingTrack.value = null;
    _restoredPositionMs = null;
    await PlaySession.clear();
    await updateQueue([]);
    // 不调 super.stop()：playbackEventStream 正在 pipe（addStream）时向
    // playbackState 添加事件会抛 rxdart "cannot add items" 竞态；
    // 队列已清、播放已停，锁屏状态会随事件流自然更新。
    notifyListeners();
  }

  Future<void> jumpToIndex(int target) async {
    if (target < 0 || target >= _tracks.length) return;
    _index = target;
    notifyListeners();
    if (_radio != null) _maybeExtendRadio();
    await _load();
  }

  /// 音质档位切换后重载当前曲：旧档位**继续播**，新档位准备好后无缝接管
  /// （进度以接管前一刻为准连续衔接）——对齐官方切档体验：等待期不转圈、
  /// 不锁进度条、不静音。失败只报错，旧档不受影响。
  /// 恢复态（音频未加载）无需重载——下次点播放自然按新档位下载。
  Future<void> reloadCurrent() async {
    if (currentTrack == null || restoring) return;
    await _load(qualityReload: true);
  }

  Future<void> _load({
    int? initialSeekMs,
    bool autoPlay = true,
    bool qualityReload = false,
    bool sourceReload = false,
  }) async {
    final track = currentTrack;
    if (track == null) return;
    final seq = ++_loadSeq;
    // 无缝重载（音质切档 / 音源切换）：旧流继续播，新流就绪即接管。
    final seamless = qualityReload || sourceReload;
    final restoreMs = _restoredPositionMs;
    _restoredPositionMs = null;
    var seekTo = initialSeekMs ?? restoreMs;
    // 定时暂停模式下快照本次加载开始时的睡眠截止点：到点若落在准备/
    // 下载窗口内，pause() 打在 idle 播放器上无效，须在开播前拦下
    final sleepDeadlineAtStart = _sleepDeadline;
    lastError = null;
    if (seamless) {
      // 无缝重载：旧流还在播，档位/音源标签保持旧值、不转圈（UI 一切
      // 照旧）。带缓存直通标记的条目（已缓存曲目点播）要清掉标记并
      // 绕过直通——否则重载后永远播旧档/旧源的缓存文件。
      appLog('player: ${sourceReload ? 'source' : 'quality'} reload '
          '"${track.title}" (${track.id})');
      if (track.cachedPath.isNotEmpty && _index >= 0 && _index < _tracks.length) {
        _tracks[_index] = track.copyWithCache(cachedPath: '', cachedQuality: '');
      }
    } else {
      currentQuality = '';
      currentSourceLabel = '';
      currentSizeBytes = null;
      preparingTrack.value = track;
      notifyListeners();
      appLog('player: load "${track.title}" (${track.id})'
          '${seekTo == null ? '' : ' 续播@${seekTo}ms'}');
      // 立即停掉上一首的音频：否则准备期间旧曲仍在播、进度条仍显示旧曲
      // 位置——切歌卡在「下载/解密中」转圈时进度点停在半路的错乱观感
      // （2026-10-09 用户反馈）即来源于此。
      await _player.stop();
    }
    try {
      final t0 = DateTime.now();
      final prepared = await Api.prepareTrack(
        track,
        refreshQuality: seamless,
      ).timeout(
        _prepareBudget,
        onTimeout: () =>
            throw TimeoutException('准备播放超时（${_prepareBudget.inSeconds}s）'),
      );
      appLog('player: prepare ${DateTime.now().difference(t0).inMilliseconds}ms '
          '(quality=${prepared.quality}${prepared.streaming ? ', streaming' : ''})');
      if (seq != _loadSeq) {
        appLog('player: prepare 结果过期丢弃 (seq=$seq/$_loadSeq)');
        return; // 用户已切到别的歌
      }
      if (sourceReload &&
          prepared.quality.contains('试听') &&
          !currentQuality.contains('试听')) {
        // 换源降级保护：新源只拿到试听（如 lx 链全失败回落汽水试听）
        // 而旧流是整曲时放弃接管——保持旧源继续播，标签如实维持旧值。
        appLog('player: 换源仅得试听，放弃接管（旧源继续播）');
        return;
      }
      if (seamless) {
        // 等待期旧流还在走：接管位置/播放状态取此刻最新值（而非重载
        // 开始时的快照），期间用户暂停或拖动过都以最新为准
        final nowMs = _player.position.inMilliseconds;
        if (nowMs > 1000) seekTo = nowMs;
        autoPlay = _player.playing;
      }
      final t1 = DateTime.now();
      var effective = prepared;
      Duration? duration;
      if (prepared.streaming) {
        try {
          duration = await _player.setUrl(
            prepared.url,
            headers:
                prepared.ua.isEmpty ? null : {'User-Agent': prepared.ua},
          );
        } catch (error) {
          // CDN 校验 UA / 直链失效等：回退整曲下载，拿本地文件再播
          appLog('player: setUrl 失败，回退整曲下载: $error');
          if (seq != _loadSeq) return;
          effective = await Api.prepareTrack(
            track,
            forceDownload: true,
            refreshQuality: seamless,
          ).timeout(
            _prepareBudget,
            onTimeout: () => throw TimeoutException(
                '准备播放超时（${_prepareBudget.inSeconds}s）'),
          );
          if (seq != _loadSeq) return;
        }
      }
      if (!effective.streaming) {
        duration = await _player.setFilePath(effective.path);
      }
      appLog('player: ${effective.streaming ? 'setUrl' : 'setFilePath'} '
          '${DateTime.now().difference(t1).inMilliseconds}ms');
      if (seq != _loadSeq) return;
      // 续播位置已到结尾（或超长）时放弃 seek，从头播放
      final totalMs = duration?.inMilliseconds ??
          track.durationSeconds * 1000;
      if (seekTo != null && totalMs > 0 && seekTo >= totalMs - 1500) {
        seekTo = null;
      }
      if (seekTo != null && seekTo > 0) {
        await _player.seek(Duration(milliseconds: seekTo));
        if (seq != _loadSeq) return;
      }
      currentQuality = store.qualityTierOf(effective.quality);
      currentSourceLabel = effective.origin;
      currentSizeBytes = effective.sizeBytes;
      // iOS 锁屏封面只认本地 file://（远程 URL 不会代抓），但本地封面
      // 异步下载补上、不阻塞开播——弱网下封面下载不再拖住起播
      // （缓存曲目点播等本地/秒开场景尤其明显）。
      final item = MediaItem(
        id: track.id,
        title: track.title,
        artist: track.artist,
        album: track.album,
        artUri:
            track.cover.isEmpty ? null : Uri.tryParse(track.cover),
        duration: duration ??
            (track.durationSeconds > 0
                ? Duration(seconds: track.durationSeconds)
                : null),
      );
      mediaItem.add(item);
      unawaited(() async {
        final local = await _localCoverUri(track);
        // 封面下载期间已切歌：过期结果不再覆盖新曲目的锁屏信息
        if (local != null && seq == _loadSeq) {
          mediaItem.add(item.copyWith(artUri: local));
        }
      }());
      // play() 在 iOS 上可能到曲目结束才 resolve（实测 60s 试听曲挂满全程），
      // 不能阻塞 finally（清 preparing 转圈），异步等待并单独记错。
      if (autoPlay &&
          sleepDeadlineAtStart != null &&
          DateTime.now().isAfter(sleepDeadlineAtStart)) {
        // 睡眠定时在准备期间到点：不自动续响，保持暂停等用户点播
        autoPlay = false;
        appLog('player: 睡眠定时已在准备期间到点，加载完成不自动播放');
      }
      if (autoPlay) {
        final t2 = DateTime.now();
        unawaited(_player.play().then((_) {
          appLog('player: play ${DateTime.now().difference(t2).inMilliseconds}ms, '
              'playing=${_player.playing}');
        }).catchError((Object error) {
          appLog('player: play 异步失败: $error');
        }));
      }
      unawaited(PlayHistory.record(track));
      unawaited(PlayStats.record(track));
      if (_radio != null) _radio!.markPlayed(track.id);
      unawaited(_prefetchNext());
      unawaited(_saveSession(positionMs: seekTo ?? 0));
    } catch (error) {
      if (seq != _loadSeq) return;
      lastError = error.toString();
      logError('player.load', error);
      // 无缝重载失败：旧流还在正常播，只报错不跳歌、不清场
      if (seamless) return;
      // 自动跳下一首（队列里还有别的歌时）
      if (_tracks.length > 1) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (seq == _loadSeq) {
          await skipToNext();
        }
      }
    } finally {
      if (seq == _loadSeq) {
        if (!seamless) preparingTrack.value = null;
        notifyListeners();
      }
    }
  }

  /// 封面本地缓存 URI：复用 CoverImage 的共享缓存（内存 + 磁盘，
  /// `<covers>/<fnv64(url)>.img`）——列表里显示过的封面零下载直接命中，
  /// 不再为锁屏封面重复下载一份。
  Future<Uri?> _localCoverUri(Track track) async {
    final file = await resolveCoverFile(track.cover);
    return file == null ? null : Uri.file(file.path);
  }

  /// 预取下一首：Rust 缓存命中后真正播放时几乎瞬时。
  ///
  /// 延迟 4s 触发：把带宽/请求优先级让给刚切歌后的 UI 请求（歌词、
  /// 封面、页面加载），也避开用户快速连点切歌的浪费。
  Future<void> _prefetchNext() async {
    final next = _nextIndex();
    if (next < 0 || next == _index) return;
    final track = _tracks[next];
    final seqAtSchedule = _loadSeq;
    await Future<void>.delayed(const Duration(seconds: 4));
    if (seqAtSchedule != _loadSeq || currentTrack?.id == track.id) {
      return; // 期间已切歌或已播到该曲
    }
    try {
      final t0 = DateTime.now();
      // forceDownload：预取语义是「下一首秒播」——明文流也提前整曲落盘
      // （点播/切档才走流式直链快路径），真播时文件缓存命中瞬时开播。
      await Api.prepareTrack(track, forceDownload: true);
      appLog('player: prefetch "${track.title}" '
          '${DateTime.now().difference(t0).inMilliseconds}ms');
    } catch (error) {
      appLog('player: 预取失败(忽略): $error');
    }
  }

  Future<void> cyclePlayMode() async {
    playMode = switch (playMode) {
      PlayMode.sequence => PlayMode.repeatOne,
      PlayMode.repeatOne => PlayMode.shuffle,
      PlayMode.shuffle => PlayMode.sequence,
    };
    await _saveSession();
    notifyListeners();
  }

  /// 播放速度（持久化由调用方负责，这里只作用到播放器；
  /// 覆盖 BaseAudioHandler 以同时接管锁屏/远程调速回调）。
  @override
  Future<void> setSpeed(double value) async {
    if (value <= 0 || value > 3) return;
    await _player.setSpeed(value);
    notifyListeners();
  }

  Future<void> toggle() async {
    // 准备中（已 stop 旧音频）：忽略点按，加载完成按 autoPlay 自动开播
    if (preparingTrack.value != null) return;
    if (_player.playing) {
      await pause();
    } else {
      if (!hasCurrent && _tracks.isNotEmpty) {
        await jumpToIndex(0);
        return;
      }
      if (restoring) {
        // 恢复态首次播放：加载音频并跳到上次进度
        await _load();
        return;
      }
      await _replayIfCompleted();
      await _player.play();
    }
  }

  @override
  Future<void> play() async {
    if (preparingTrack.value != null) return;
    if (restoring) {
      await _load();
      return;
    }
    await _replayIfCompleted();
    await _player.play();
  }

  /// 曲终态（如睡眠定时「播完即停」后）再按播放：源已耗尽，直接 play()
  /// 会立即完成且无声——从头重播当前曲。
  Future<void> _replayIfCompleted() async {
    if (_player.processingState != ProcessingState.completed) return;
    await _player.seek(Duration.zero);
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    if (!restoring) await _saveSession();
  }

  @override
  Future<void> stop() async {
    await _player.pause();
    await super.stop();
  }

  @override
  Future<void> skipToNext() => jumpToIndex(_nextIndex());

  @override
  Future<void> skipToPrevious() => jumpToIndex(_previousIndex());

  @override
  Future<void> seek(Duration position) async {
    // 准备中音频源已停（idle）：此时 seek 无意义且底层会抛错
    if (preparingTrack.value != null) return;
    await _player.seek(position);
    if (!restoring) await _saveSession();
  }

  @override
  Future<void> skipToQueueItem(int index) => jumpToIndex(index);

  PlaybackState _transformEvent(PlaybackEvent event) => PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (_player.playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: switch (_player.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: _player.playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: event.currentIndex,
      );
}
