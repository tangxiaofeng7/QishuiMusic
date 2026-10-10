import 'package:flutter/material.dart';

import '../../core/play_stats.dart';
import '../../main.dart';
import '../nav.dart';
import '../widgets/cover.dart';
import '../widgets/track_sheet.dart';

/// 听歌排行（本机播放统计）：最近一周 / 全部两个榜，
/// TOP 曲目点击即从该曲开始整榜播放。
class RankingPage extends StatefulWidget {
  const RankingPage({super.key});

  @override
  State<RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<RankingPage> {
  bool _weekly = true;
  List<PlayStatsEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await PlayStats.top(weekly: _weekly);
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  void _switchTab(bool weekly) {
    if (_weekly == weekly) return;
    setState(() {
      _weekly = weekly;
      _entries = null;
    });
    _load();
  }

  void _playAll(List<PlayStatsEntry> entries, [int startIndex = 0]) {
    final tracks = entries.map((entry) => entry.track).toList();
    player.playQueue(tracks, startIndex);
    openPlayerTab(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: const Text('听歌排行')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('最近一周')),
                    ButtonSegment(value: false, label: Text('全部')),
                  ],
                  selected: {_weekly},
                  onSelectionChanged: (selection) =>
                      _switchTab(selection.first),
                ),
                const Spacer(),
                if (entries != null && entries.isNotEmpty)
                  IconButton(
                    tooltip: '播放整个榜单',
                    icon: const Icon(Icons.play_circle),
                    onPressed: () => _playAll(entries),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              '本机播放统计 · 滚动 7 天 · 与最近播放同源计数',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
          if (entries == null)
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (entries.isEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.leaderboard_outlined,
                        size: 52, color: scheme.outline),
                    const SizedBox(height: 12),
                    const Text('还没有统计数据'),
                    const SizedBox(height: 6),
                    Text(
                      '播放歌曲后，这里会生成你的专属榜单',
                      style:
                          TextStyle(fontSize: 12, color: scheme.outline),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final count = _weekly ? entry.week : entry.total;
                  return _RankTile(
                    rank: index + 1,
                    entry: entry,
                    count: count,
                    onTap: () => _playAll(entries, index),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _RankTile extends StatelessWidget {
  const _RankTile({
    required this.rank,
    required this.entry,
    required this.count,
    required this.onTap,
  });

  final int rank;
  final PlayStatsEntry entry;
  final int count;
  final VoidCallback onTap;

  static const _medalColors = [
    Color(0xFFFFC53D), // 金
    Color(0xFFB8C4CE), // 银
    Color(0xFFCE8A5B), // 铜
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = entry.track;
    final medal = rank <= 3;
    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '$rank',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: medal ? 16 : 14,
                fontWeight: medal ? FontWeight.w800 : FontWeight.w500,
                color: medal ? _medalColors[rank - 1] : scheme.outline,
                fontFeatures: [const FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: CoverImage(url: track.cover, size: 44),
          ),
        ],
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          if (track.artist.isNotEmpty) track.artist,
          if (track.platformLabel.isNotEmpty) track.platformLabel,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        '$count 次',
        style: TextStyle(fontSize: 12.5, color: scheme.outline),
      ),
      onTap: onTap,
      onLongPress: () => showTrackSheet(context, track),
    );
  }
}
