/// 电台会话：官方「无限电台」的客户端状态机。
///
/// 生命周期由 [PlayerController] 驱动（避免循环依赖，本类不 import 播放器）：
/// * 开播：`player.startRadio(station)` 拉首批建队列；
/// * 续播：切歌时队列余量不足，播放器调 [fetchMore] 追加；
/// * 不喜欢：[dislike] 加入本会话黑名单，播放器跳下一首；
/// * 结束：播放普通队列 / 清空队列时播放器置空引用。
///
/// 服务端回包同参重拉内容会轮换（与歌单广场同语义），无游标可续；
/// 去重由 [fetchMore] 按「已播 + 不喜欢 + 队列已有」三层过滤兜底。

library;

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'logging.dart';
import 'models.dart';

class RadioSession extends ChangeNotifier {
  RadioSession(this.station);

  /// 当前电台（null 由播放器侧表达，本类一旦存在即活跃）。
  final RadioStation station;

  /// 本会话已播曲目（发给服务端换血；上限防请求体膨胀）。
  final Set<String> _played = {};

  /// 本会话「不喜欢」的曲目（客户端过滤 + 服务端换血同用）。
  final Set<String> _disliked = {};

  /// 播放器侧标记「追加中」，防切歌风暴重复拉取。
  bool extending = false;

  /// `feed:familiar` / `feed:fresh` 形态的「私人FM」特殊电台：
  /// 走官方个性化推荐队列（feed/song-tab），不依赖电台端点。
  bool get isFeedStation => station.id.startsWith('feed:');

  /// feed 引擎的翻页计数（每次续播 +1，服务端按此换血）。
  int _feedCounter = 0;

  /// 已连续失败的追加次数（连续 2 次后放弃本会话自动续播，等手动切歌再试）。
  int extendFailures = 0;

  List<String> get playedIds =>
      _played.take(300).toList(growable: false);

  /// 当前曲目开播时登记（由播放器在 _load 时调用）。
  void markPlayed(String trackId) {
    if (trackId.isEmpty || _played.contains(trackId)) return;
    _played.add(trackId);
    notifyListeners();
  }

  /// 不喜欢当前曲：拉黑 + 播放器跳下一首。
  void dislike(String trackId) {
    if (trackId.isEmpty) return;
    _disliked.add(trackId);
    _played.add(trackId);
    notifyListeners();
  }

  /// 拉下一批（播放器在队列余量不足时调用）。
  ///
  /// [queueIds] 是当前队列已有的曲目 id，用于客户端去重；返回过滤后的
  /// 一批（可能为空——空也算成功，只是服务端没新货）。
  ///
  /// 两种取流引擎：`feed:*` 特殊电台走官方个性化推荐队列（熟悉/新鲜
  /// 模式，实测免风控），普通电台 id 走 `/luna/feed/radio/tracks`。
  Future<List<Track>> fetchMore(Set<String> queueIds) async {
    if (extending) return const [];
    extending = true;
    notifyListeners();
    try {
      final List<Track> fetched;
      if (isFeedStation) {
        final page = await Api.feed(
          fetchCounter: ++_feedCounter,
          subQueueType: station.id.substring(5),
        );
        fetched = page.tracks;
      } else {
        final page = await Api.radioTracks(
          station.id,
          playedIds: playedIds,
          count: 20,
        );
        fetched = page.tracks;
      }
      final excluded = {...queueIds, ..._disliked};
      final fresh = fetched
          .where((track) =>
              track.id.isNotEmpty && !excluded.contains(track.id))
          .toList();
      extendFailures = 0;
      return fresh;
    } catch (error) {
      extendFailures++;
      appLog('radio: 追加失败 #$extendFailures（${station.title}）: $error');
      return const [];
    } finally {
      extending = false;
      notifyListeners();
    }
  }
}
