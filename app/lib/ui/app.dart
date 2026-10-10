import 'package:flutter/material.dart';

import '../brand.dart';
import '../core/lx_runtime.dart';
import '../core/signer_bridge.dart';
import '../main.dart';
import 'nav.dart';
import 'pages/discover_page.dart';
import 'pages/home_page.dart';
import 'pages/mine_page.dart';
import 'pages/player_page.dart';
import 'pages/settings_page.dart';

class QishuiApp extends StatefulWidget {
  const QishuiApp({super.key});

  @override
  State<QishuiApp> createState() => _QishuiAppState();
}

class _QishuiAppState extends State<QishuiApp> {
  ThemeMode _themeMode() => switch (settings.themeMode) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      };

  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    // 主题 seed：个性化外观（跟随封面取色 / 预设色板）即时生效。
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) {
        final seed = appearance.effectiveAccent;
        return MaterialApp(
          title: kAppName,
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          themeMode: _themeMode(),
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: seed,
              brightness: Brightness.light,
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: seed,
              brightness: Brightness.dark,
            ),
          ),
          home: Stack(
            children: [
              _HomeShell(onSettingsChanged: _refresh),
              // 内置签名页（1x1 隐藏 WebView，常驻；扫码登录的 a_bogus 签名靠它）
              const Positioned(
                left: -2,
                top: -2,
                child: SignerBridgeView(),
              ),
              // lx 用户脚本运行时（1x1，必须在屏幕内——离屏 WebView 会被
              // iOS 节流，脚本请求会拖到 30s+；左上角 1px 视觉无感知）
              const Positioned(
                left: 0,
                top: 0,
                child: LxRuntimeView(),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HomeShell extends StatefulWidget {
  const _HomeShell({required this.onSettingsChanged});

  final VoidCallback onSettingsChanged;

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  int _tab = 0;

  /// 懒加载 Tab 集：首次选中才挂载（播放页提前挂载会对每首歌白跑
  /// 歌词 / 取色请求）；挂载后随 IndexedStack 保活。
  final Set<int> _mounted = {0};

  @override
  void initState() {
    super.initState();
    homeTabIndex.addListener(_onTabSwitched);
  }

  @override
  void dispose() {
    homeTabIndex.removeListener(_onTabSwitched);
    super.dispose();
  }

  /// Tab 切换统一入口：底部栏点击与深层页面（nav.dart）都改
  /// homeTabIndex，由这里同步 UI；页面可监听它感知「自己被切到」。
  void _onTabSwitched() {
    setState(() {
      _tab = homeTabIndex.value;
      _mounted.add(_tab);
    });
  }

  void _select(int value) => homeTabIndex.value = value;

  @override
  Widget build(BuildContext context) {
    // IndexedStack 保活：切 Tab 不销毁页面（「我的」页缓存的数据不重拉，
    // 各页滚动位置/状态也保留）。children 顺序固定，Element 树复用 State。
    final pages = [
      const HomePage(),
      const DiscoverPage(),
      const PlayerPage(),
      MinePage(onSettingsChanged: widget.onSettingsChanged),
      SettingsPage(onSettingsChanged: widget.onSettingsChanged),
    ];
    return Scaffold(
      // 播放器是常驻 Tab（不再是路由页），迷你条已移除——
      // 有曲目在播时播放 Tab 图标加小圆点提示。
      body: IndexedStack(
        index: _tab,
        children: [
          for (var i = 0; i < pages.length; i++)
            _mounted.contains(i) ? pages[i] : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final hasTrack = player.currentTrack != null;
          return NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: _select,
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: '首页',
              ),
              const NavigationDestination(
                icon: Icon(Icons.explore_outlined),
                selectedIcon: Icon(Icons.explore),
                label: '发现',
              ),
              NavigationDestination(
                icon: _playerTabIcon(false, hasTrack),
                selectedIcon: _playerTabIcon(true, hasTrack),
                label: '播放',
              ),
              const NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: '我的',
              ),
              const NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: '设置',
              ),
            ],
          );
        },
      ),
    );
  }

  /// 播放 Tab 图标：均衡器图形；有当前曲目时叠小圆点（替代原迷你条
  /// 的「正在播放」提示）。
  Widget _playerTabIcon(bool selected, bool hasTrack) {
    final icon =
        Icon(selected ? Icons.graphic_eq : Icons.graphic_eq_outlined);
    return hasTrack ? Badge(smallSize: 8, child: icon) : icon;
  }
}
