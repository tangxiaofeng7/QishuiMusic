import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../main.dart';
import '../nav.dart';
import 'cover.dart';
import 'track_sheet.dart';

/// 曲目行：封面 / 标题 / 歌手·专辑 / 时长 / 正在播放指示 / 喜欢标记。
///
/// 长按或点右侧「更多」弹出操作菜单（查看歌手 / 查看专辑）。
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.queue,
    this.showIndex = false,
    this.index = 0,
    this.trailing,
    this.showMore = true,
  });

  final Track track;
  final List<Track> queue;
  final bool showIndex;
  final int index;
  final Widget? trailing;

  /// 是否在行尾显示「更多」按钮（队列底单等紧凑场景可关）。
  final bool showMore;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([player, likedStore]),
      builder: (context, _) {
        final playing = player.currentTrack?.id == track.id;
        final preparingThis =
            player.preparingTrack.value?.id == track.id && playing;
        final liked = likedStore.isLiked(track.id);
        return ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          leading: showIndex
              ? SizedBox(
                  width: 48,
                  child: Center(
                    child: preparingThis
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            '${index + 1}',
                            style: TextStyle(
                              color: playing
                                  ? scheme.primary
                                  : scheme.outline,
                            ),
                          ),
                  ),
                )
              : SizedBox(
                  width: 48,
                  height: 48,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: CoverImage(url: track.cover, size: 48),
                        ),
                      ),
                      if (liked)
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: scheme.surface,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.favorite,
                              size: 13,
                              color: Colors.pinkAccent.shade200,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: playing ? scheme.primary : null,
              fontWeight: playing ? FontWeight.w600 : null,
            ),
          ),
          subtitle: Text(
            [
              if (track.vip) 'VIP',
              if (track.platformLabel.isNotEmpty) track.platformLabel,
              if (track.artist.isNotEmpty) track.artist,
              if (track.album.isNotEmpty) track.album,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: trailing ??
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    player.currentTrack?.id == track.id && player.currentQuality.isNotEmpty
                        ? player.currentQuality
                        : track.durationLabel,
                    style: TextStyle(color: scheme.outline, fontSize: 12),
                  ),
                  if (showMore)
                    SizedBox(
                      width: 34,
                      height: 40,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.more_vert,
                            size: 18, color: scheme.outline),
                        onPressed: () => showTrackSheet(context, track),
                      ),
                    ),
                ],
              ),
          // 点正在播放的这首 → 切到播放 Tab（不打断重播，对齐全局惯例）
          onTap: () {
            if (playing) {
              openPlayerTab(context);
              return;
            }
            player.playQueue(queue, queue.indexOf(track));
          },
          onLongPress: () => showTrackSheet(context, track),
        );
      },
    );
  }
}
