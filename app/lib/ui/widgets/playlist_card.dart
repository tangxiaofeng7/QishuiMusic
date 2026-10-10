import 'package:flutter/material.dart';

import 'cover.dart';

/// 歌单卡片：封面 + 标题 + 副标题（横条/网格两用，[width] 定宽或撑满）。
/// 首页「为你推荐」与发现页共用同一形态。
class PlaylistCard extends StatelessWidget {
  const PlaylistCard({
    super.key,
    required this.cover,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.width,
    this.rankBadge,
  });

  final String cover;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// 定宽（横滑列表用）；null = 撑满（网格用）。
  final double? width;

  /// 排行榜角标（前三名显示名次）。
  final String? rankBadge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: CoverImage(url: cover, size: 256),
                  ),
                ),
                if (rankBadge != null)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        rankBadge!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            if (subtitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  subtitle,
                  maxLines: 1,
                  style: TextStyle(fontSize: 11.5, color: scheme.outline),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
