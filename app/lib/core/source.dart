/// 播放音源切换通知（会话内存共享）。
///
/// 首页/发现/搜索/我的都按当前音源渲染不同内容，切换必须让这些页面
/// 立即换装。`settings.sourceMode` 仍是唯一事实源，这里只做统一的
/// 「切换 + 落盘 + 重配 FFI + 广播」，避免各页面各自监听设置对象。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'lx_runtime.dart';
import 'store.dart' as store;

class SourceStore extends ChangeNotifier {
  /// 当前播放音源（'default' = 汽水账号；'lx' = 其他音源）。
  /// main 启动时 activeSettings 即全局 settings 实例，二者同源。
  String get mode => store.activeSettings?.sourceMode ?? 'default';

  bool get isLx => store.activeSettings?.sourceMode == 'lx';

  /// 其他音源下的曲库平台（'kw' = 酷我 / 'wy' = 网易云）。
  String get platform => store.activeSettings?.lxPlatform ?? 'kw';

  /// lx 模式下的激活取流脚本 id（'' = 未选定：解析链聚合兜底，
  /// UI 已不提供该选项，仅作旧数据防御）。
  String get script => store.activeSettings?.lxScript ?? '';

  /// 统一切换入口：设置页音源列表与各详情页「设为当前音源」共用。
  /// 切换即持久化并重建 Rust 会话（取流分流随之生效），然后广播。
  Future<void> switchTo(String mode) async {
    final settings = store.activeSettings;
    if (settings == null || settings.sourceMode == mode) return;
    settings.sourceMode = mode;
    await settings.save();
    final cacheDir = await store.Settings.resolveCacheDir();
    await Api.configure(settings.toFfiConfig(cacheDir));
    if (mode == 'lx') warmActiveScript();
    notifyListeners();
  }

  /// 切换 LX 曲库平台（首页/发现/搜索三页联动）。
  Future<void> switchPlatform(String platform) async {
    final settings = store.activeSettings;
    if (settings == null || settings.lxPlatform == platform) return;
    settings.lxPlatform = platform;
    await settings.save();
    notifyListeners();
  }

  /// 切换激活取流脚本。曲库平台是独立的搜索/榜单
  /// 维度，不随脚本收敛：lx 模式下选定脚本独占首攻（解析链会等它
  /// 就绪），失败才由其余就绪脚本回退。
  Future<void> switchScript(String scriptId) async {
    final settings = store.activeSettings;
    if (settings == null || settings.lxScript == scriptId) return;
    settings.lxScript = scriptId;
    await settings.save();
    // 换了脚本 = 换音源：旧脚本的首攻熔断不复用（对齐 lx-music 选择
    // 即重新初始化）。
    Api.resetActiveScriptFuse();
    if (scriptId.isNotEmpty) warmActiveScript();
    notifyListeners();
  }

  /// 选定即初始化（对齐 lx-music：音源选择后立即初始化脚本，状态在
  /// 列表可见）。解析链在未就绪时会等待，这里只是把加载提前到用户
  /// 浏览曲库的空档——第一次点歌时脚本多半已就绪，秒出链。
  void warmActiveScript() {
    final id = store.activeSettings?.lxScript ?? '';
    if (id.isEmpty) return;
    unawaited(() async {
      await LxRuntime.instance.ensureStarted();
      final script = LxRuntime.instance.scriptById(id);
      if (script != null && !script.ready && script.error.isEmpty) {
        await LxRuntime.instance.loadScript(id);
      }
    }());
  }
}

final sourceStore = SourceStore();
