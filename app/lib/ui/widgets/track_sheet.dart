import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../main.dart';
import '../pages/album_page.dart';
import 'cover.dart';
import '../pages/artist_page.dart';

/// 曲目「更多」操作底单：喜欢（全局本地）/ 查看歌手 / 查看专辑。
Future<void> showTrackSheet(BuildContext context, Track track) async {
  final scheme = Theme.of(context).colorScheme;
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: CoverImage(url: track.cover, size: 44),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (track.artist.isNotEmpty)
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.outline,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 喜欢（App 全局，本机存储；平台曲目同样可喜欢）
          ListTile(
            leading: Icon(
              likedStore.isLiked(track.id)
                  ? Icons.favorite
                  : Icons.favorite_border,
              color: scheme.error,
            ),
            title: Text(likedStore.isLiked(track.id) ? '取消喜欢' : '喜欢'),
            subtitle: const Text('本机「我喜欢的音乐」，所有音源共用',
                style: TextStyle(fontSize: 12)),
            onTap: () => Navigator.of(sheetContext).pop('like'),
          ),
          // 插队播放（借鉴 Beans-Music 的播放队列插队）
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('下一首播放'),
            subtitle: const Text('插到当前队列的下一首，不影响其余顺序',
                style: TextStyle(fontSize: 12)),
            onTap: () => Navigator.of(sheetContext).pop('next'),
          ),
          if (track.artistId.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text('歌手：${track.artist}'),
              onTap: () => Navigator.of(sheetContext).pop('artist'),
            ),
          if (track.albumId.isNotEmpty && track.album.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.album_outlined),
              title: Text('专辑：${track.album}'),
              onTap: () => Navigator.of(sheetContext).pop('album'),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case 'like':
      final liked = likedStore.toggle(track);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(liked ? '已加入「我喜欢的音乐」' : '已取消喜欢'),
            duration: const Duration(seconds: 1),
          ),
        );
    case 'next':
      await player.insertNext(track);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('下一首将播放「${track.title}」'),
            duration: const Duration(seconds: 1),
          ),
        );
    case 'artist':
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ArtistPage(artistId: track.artistId, name: track.artist),
      ));
    case 'album':
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => AlbumPage(
          albumId: track.albumId,
          title: track.album,
          artist: track.artist,
          cover: track.cover,
        ),
      ));
  }
}
