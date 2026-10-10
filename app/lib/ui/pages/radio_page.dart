import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/errors.dart';
import '../../core/models.dart';
import '../../core/page_cache.dart';
import '../../main.dart';
import '../nav.dart';
import '../widgets/cover.dart';
import '../widgets/skeleton.dart';

/// 电台页（汽水FM）：官方发现页的 discover_radio 电台站。
///
/// 点击即开播：拉首批进队列，队列余量不足自动续拉（无限电台语义），
/// 播放页可「不喜欢」换下一首。需要登录（接口带账号 Cookie）。
class RadioPage extends StatefulWidget {
  const RadioPage({super.key});

  @override
  State<RadioPage> createState() => _RadioPageState();
}

class _RadioPageState extends State<RadioPage> {
  List<RadioStation> _stations = [];
  bool _loading = false;
  String? _error;
  String _startingId = '';

  @override
  void initState() {
    super.initState();
    _restoreFromCache();
    _reload();
  }

  /// 首屏 SWR：电台目录稳定（12 台种子 + 私人FM 卡），上次列表先上屏。
  /// FFI 侧列表端点被风控时要走三级回落（逐个超时），缓存可跳过整段等待。
  Future<void> _restoreFromCache() async {
    final stations = await PageCache.readList(
        'radio-stations', 'stations', RadioStation.fromJson);
    if (stations.isEmpty || !mounted) return;
    if (_stations.isNotEmpty || _loading == false) return; // 网络更快/已就绪
    setState(() => _stations = stations);
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stations = await Api.radioList();
      if (!mounted) return;
      setState(() => _stations = stations);
      if (stations.isEmpty) {
        _error = '电台列表暂无内容，下拉刷新重试';
      } else {
        unawaited(PageCache.writeList('radio-stations', 'stations',
            stations.map((item) => item.toJson()).toList()));
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _start(RadioStation station) async {
    if (_startingId.isNotEmpty) return;
    setState(() => _startingId = station.id);
    try {
      await player.startRadio(station);
      if (!mounted) return;
      openPlayerTab(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
    } finally {
      if (mounted) setState(() => _startingId = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('汽水FM · 无限电台')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    Icon(Icons.radio, size: 18, color: scheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '点一个电台开始无限畅听；播放中可「不喜欢」随时换歌',
                        style:
                            TextStyle(fontSize: 12.5, color: scheme.outline),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 私人FM：官方个性化推荐引擎（熟悉/新鲜模式），不依赖电台端点
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Row(
                  children: [
                    for (final (icon, title, desc, id) in const [
                      (Icons.history, '熟悉模式', '常听的味道，越听越对味', 'familiar'),
                      (Icons.auto_awesome, '新鲜模式', '没听过的惊喜，探索新歌', 'fresh'),
                    ])
                      Expanded(
                        child: Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 4),
                          child: InkWell(
                            onTap: () => _start(RadioStation(
                              id: 'feed:$id',
                              title: title,
                              desc: desc,
                            )),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor:
                                        scheme.primaryContainer,
                                    child: Icon(icon,
                                        size: 20, color: scheme.primary),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(title,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700)),
                                        const SizedBox(height: 2),
                                        Text(desc,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                fontSize: 11.5,
                                                color: scheme.outline)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_loading && _stations.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: SkeletonBody(count: 6),
              )
            else if (_error != null && _stations.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: ListView(
                  children: [
                    const SizedBox(height: 120),
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(child: Text(_error!)),
                    ),
                    Center(
                      child: FilledButton.tonal(
                        onPressed: _reload,
                        child: const Text('重试'),
                      ),
                    ),
                  ],
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                sliver: SliverGrid(
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.92,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _StationCard(
                      station: _stations[index],
                      starting: _startingId == _stations[index].id,
                      onTap: () => _start(_stations[index]),
                    ),
                    childCount: _stations.length,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 电台卡：封面 + 名称 + 描述（服务端主色作底，让列表有「调频」质感）。
class _StationCard extends StatelessWidget {
  const _StationCard({
    required this.station,
    required this.starting,
    required this.onTap,
  });

  final RadioStation station;
  final bool starting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = station.dominantColor ?? scheme.primary;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: starting ? null : onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 封面铺底（StackFit.expand 拉满卡片）；无封面用服务端主色渐变兜底
            if (station.cover.isNotEmpty)
              CoverImage(url: station.cover)
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [tint, Color.lerp(tint, Colors.black, 0.45)!],
                  ),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.45, 1],
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.72),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    station.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  if (station.desc.isNotEmpty)
                    Text(
                      station.desc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.white.withValues(alpha: 0.82),
                      ),
                    ),
                ],
              ),
            ),
            if (starting)
              Container(
                color: Colors.black38,
                alignment: Alignment.center,
                child: const CircularProgressIndicator(color: Colors.white),
              ),
          ],
        ),
      ),
    );
  }
}
