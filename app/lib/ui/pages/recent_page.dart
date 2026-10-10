import 'package:flutter/material.dart';

import '../../core/history.dart';
import '../../core/logging.dart';
import '../../core/models.dart';
import '../../main.dart';
import '../widgets/skeleton.dart';
import '../widgets/track_tile.dart';

/// 最近播放（仅本机，不上报服务端）。支持左滑删除单条。
class RecentPage extends StatefulWidget {
  const RecentPage({super.key});

  @override
  State<RecentPage> createState() => _RecentPageState();
}

class _RecentPageState extends State<RecentPage> {
  List<Track> _tracks = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final tracks = await PlayHistory.load();
      if (mounted) {
        setState(() {
          _tracks = tracks;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _delete(Track track) async {
    final index = _tracks.indexOf(track);
    if (index < 0) return;
    setState(() => _tracks.removeAt(index));
    try {
      await PlayHistory.remove(track.id);
    } catch (error) {
      appLog('recent: 删除播放记录失败: $error');
      if (mounted) {
        setState(() => _tracks.insert(index, track));
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('删除失败：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('最近播放')),
      body: _loading
          ? const SkeletonBody(count: 10)
          : _error != null
              ? ListView(children: [
                  const SizedBox(height: 120),
                  Center(child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!),
                  )),
                  Center(
                    child: FilledButton.tonal(
                      onPressed: _load,
                      child: const Text('重试'),
                    ),
                  ),
                ])
              : _tracks.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 160),
                      Center(child: Text('还没有播放记录')),
                    ])
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        itemCount: _tracks.length,
                        itemBuilder: (context, index) {
                          final track = _tracks[index];
                          return Dismissible(
                            key: ValueKey('recent-${track.id}-$index'),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              color:
                                  Theme.of(context).colorScheme.errorContainer,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              child: Icon(Icons.delete_outline,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onErrorContainer),
                            ),
                            onDismissed: (_) => _delete(track),
                            child: TrackTile(
                              track: track,
                              queue: _tracks,
                            ),
                          );
                        },
                      ),
                    ),
      bottomNavigationBar: _tracks.isEmpty
          ? null
          : SafeArea(
              child: ListTile(
                tileColor: Theme.of(context).colorScheme.secondaryContainer,
                leading: const Icon(Icons.play_circle),
                title: const Text('播放全部'),
                subtitle: Text('${_tracks.length} 首'),
                onTap: () => player.playQueue(_tracks, 0),
              ),
            ),
    );
  }
}
