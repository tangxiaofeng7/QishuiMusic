/// lx-music 用户脚本运行时（WebView + 每脚本一个同源 iframe）。
///
/// 脚本不随 App 注册——原 28 个内置源已全部改为「推荐音源」按需导入
/// （内容仍打包在 assets/lx-sources/ 供导入，见 AddScriptPage）；注册表
/// 存 SharedPreferences `lxUserScripts`，脚本本体存应用容器
/// `Documents/lx_sources/<id>.js`，由 SignerBridge 的 /lx-sources/ 路由
/// 提供（用户文件优先，内置资产兜底）。
/// 协议对齐 lx-music 的用户自定义音源：脚本只做 songmid → 播放地址转换，
/// 跨平台搜索由 App 完成（kw/wy 免签）。
///
/// 运行时页必须挂在**屏幕内**（1x1）：离屏 WebView 的 JS 定时器会被 iOS
/// 激进节流（见二次验证的教训），脚本请求会拖到 30s+。

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'logging.dart';
import 'signer_bridge.dart';
import 'store.dart' show activeSettings, appContainerRoot, lxUserScriptsDirPath;

class LxScriptInfo {
  LxScriptInfo({
    required this.id,
    required this.name,
    this.builtin = false,
    this.url = '',
    this.version = '',
    this.author = '',
    this.description = '',
    this.homepage = '',
  });

  final String id;
  String name;

  /// 来源 URL（记录导入地址，详情页可改后重新下载；空 = 粘贴/打包导入）。
  String url;

  /// 脚本头部注释元信息（对齐 lx-music：@version/@author/@description/
  /// @homepage，导入时从 `/* … */` 头部解析）。
  String version;
  String author;
  String description;
  String homepage;

  /// 历史字段（原内置标记；现全部脚本都是用户导入，恒 false）。
  final bool builtin;
  bool loading = false;
  String error = '';
  bool ready = false;
  String lastLog = '';

  /// 脚本上报的更新提醒（lx-music updateAlert 协议：脚本自检版本后
  /// send('updateAlert', {log, updateUrl})；由 refreshStatus 拉取）。
  String updateLog = '';
  String updateUrl = '';

  bool get hasUpdateAlert => updateUrl.isNotEmpty || updateLog.isNotEmpty;

  /// source → qualitys（如 {'kw': ['128k','320k','flac'], 'wy': [...]}）
  Map<String, List<String>> sources = {};
}

/// 解析脚本头部注释元信息（对齐 lx-music utils.ts 的 parseScriptInfo）：
/// `/* @name x @version x @author x @description x @homepage x */`，
/// 逐行 `* @key value` 匹配，超长截断（24/36/56/1024/36）。
/// 头部不存在时返回空字段（导入侧据此决定是否回退手填名）。
({String name, String version, String author, String description,
      String homepage}) parseScriptMeta(String content) {
  final header = RegExp(r'^/\*[\s\S]+?\*/').firstMatch(content)?.group(0);
  final caps = <String, int>{
    'name': 24,
    'description': 36,
    'author': 56,
    'homepage': 1024,
    'version': 36,
  };
  final out = <String, String>{};
  if (header != null) {
    final lineRe = RegExp(r'^\s*\*\s?@(\w+)\s+(.+)$', multiLine: true);
    for (final match in lineRe.allMatches(header)) {
      final key = match.group(1)!;
      final limit = caps[key];
      if (limit == null) continue;
      var value = match.group(2)!.trim();
      if (value.length > limit) value = '${value.substring(0, limit)}…';
      out[key] = value;
    }
  }
  // 生态脚本常写 @version v1.2.1：去掉 v 前缀（展示层统一拼 v 前缀）
  var version = out['version'] ?? '';
  while (version.isNotEmpty && 'vV'.contains(version[0])) {
    version = version.substring(1).trim();
  }
  return (
    name: out['name'] ?? '',
    version: version,
    author: out['author'] ?? '',
    description: out['description'] ?? '',
    homepage: out['homepage'] ?? '',
  );
}

class LxRuntime {
  LxRuntime._();

  static final LxRuntime instance = LxRuntime._();

  static const _channelName = 'LxRuntime';

  WebViewController? _controller;
  Future<void>? _starting;
  bool _ready = false;
  bool _registryLoaded = false;
  int _cbSeq = 0;
  final Map<String, Completer<Map<String, dynamic>>> _waiters = {};
  final Map<String, LxScriptInfo> _scripts = {};

  /// 清单（assets/lx/manifest.json），启动时加载。
  List<LxScriptInfo> get scripts => _scripts.values.toList();

  bool get isReady => _ready;

  /// 启动：读清单 → 建 WebView → runtime.html 就绪。
  ///
  /// 并发调用共享同一个 Future——此前用 bool 标志让进行中的调用者
  /// 「立即返回」，LxRuntimeView 的 warmUp 在清单加载完成前空跑
  /// （预热完成 0/0），此后再无预热，脚本全靠交互懒加载。
  Future<void> ensureStarted() {
    if (_ready) return Future<void>.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    try {
      await SignerBridge.instance.ensureStarted();
      final base = SignerBridge.instance.baseUri;
      if (base.isEmpty) throw '签名桥服务未启动';
      if (!_registryLoaded) {
        _registryLoaded = true;
        await _loadUserScripts();
      }
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel(_channelName, onMessageReceived: _onMessage)
        ..setNavigationDelegate(
          NavigationDelegate(onPageFinished: (_) => _ready = true),
        )
        ..loadRequest(Uri.parse('${base}lx/runtime.html'));
      _controller = controller;
      // 等页面就绪
      for (var i = 0; i < 40 && !_ready; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (!_ready) throw 'lx 运行时页加载超时';
      appLog('lx: 运行时就绪（${_scripts.length} 个已导入脚本，按需懒加载）');
    } catch (error) {
      appLog('lx: 运行时启动失败: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // 用户自定义脚本（注册表 + 文件）
  // ---------------------------------------------------------------------------

  static const _userRegistryKey = 'lxUserScripts';

  static Future<Directory> _userScriptsDir() async {
    final root = await appContainerRoot();
    final dir = Directory(lxUserScriptsDirPath(root));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static File _userScriptFile(Directory dir, String id) =>
      File('${dir.path}/$id.js');

  /// 注册表是 SharedPreferences 里的 JSON 数组：
  /// [{"id","name","url","version","author","description","homepage"}]
  /// （后四项为头部注释元信息，老条目缺失给空）。
  static Future<List<Map<String, String>>> _readRegistry() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_userRegistryKey) ?? const [];
    final out = <Map<String, String>>[];
    for (final item in raw) {
      try {
        final value = jsonDecode(item) as Map<String, dynamic>;
        final id = value['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        out.add({
          'id': id,
          'name': value['name']?.toString() ?? id,
          'url': value['url']?.toString() ?? '',
          'version': value['version']?.toString() ?? '',
          'author': value['author']?.toString() ?? '',
          'description': value['description']?.toString() ?? '',
          'homepage': value['homepage']?.toString() ?? '',
        });
      } catch (error) {
        appLog('lx: 注册表条目解析失败: $error ← $item');
      }
    }
    appLog(
      'lx: 注册表读取 ${out.length}/${raw.length} 条'
      '${raw.isEmpty ? '（空）' : ''}',
    );
    return out;
  }

  static Future<void> _writeRegistry(List<Map<String, String>> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _userRegistryKey,
      entries.map(jsonEncode).toList(),
    );
  }

  Future<void> _loadUserScripts() async {
    try {
      final dir = await _userScriptsDir();
      final registry = await _readRegistry();
      final alive = <Map<String, String>>[];
      var pruned = false;
      for (final entry in registry) {
        if (!_userScriptFile(dir, entry['id']!).existsSync()) {
          pruned = true;
          continue;
        }
        alive.add(entry);
        _scripts[entry['id']!] = LxScriptInfo(
          id: entry['id']!,
          name: entry['name']!,
          builtin: false,
          url: entry['url'] ?? '',
          version: entry['version'] ?? '',
          author: entry['author'] ?? '',
          description: entry['description'] ?? '',
          homepage: entry['homepage'] ?? '',
        );
      }
      if (pruned) await _writeRegistry(alive);
      appLog(
        'lx: 自定义脚本注册 '
        '${_scripts.values.where((s) => !s.builtin).length} 个',
      );
    } catch (error) {
      appLog('lx: 自定义脚本注册表加载失败: $error');
    }
  }

  /// 新增自定义脚本（内容为脚本 JS 全文；url 为导入来源，可空），返回脚本 id。
  ///
  /// 对齐 lx-music 导入行为：头部注释解析元信息（名称未手填时取 @name）、
  /// 内容去重（与已有自定义脚本逐字比对，重复拒绝）。
  /// [id] 指定脚本 id（推荐音源导入时沿用原清单 id，升级前后同一源
  /// 的选择不丢）；缺省生成 u_ 前缀 id。
  Future<String> addUserScript(
    String name,
    String content, {
    String? url,
    String? id,
  }) async {
    final trimmedContent = content.trim();
    final dir = await _userScriptsDir();
    final registry = await _readRegistry();
    // 内容去重：lx-music 导入相同脚本会报「与已有的源相同」
    for (final entry in registry) {
      final file = _userScriptFile(dir, entry['id']!);
      String existing = '';
      try {
        if (file.existsSync()) existing = file.readAsStringSync().trim();
      } catch (_) {}
      if (existing.isNotEmpty && existing == trimmedContent) {
        throw '导入失败：脚本内容与已有的「${entry['name']}」相同';
      }
    }
    final meta = parseScriptMeta(content);
    final scriptId = id ?? () {
      final random = Random();
      final suffix = List.generate(
        4,
        (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[random.nextInt(36)],
      ).join();
      return 'u_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$suffix';
    }();
    if (_scripts.containsKey(scriptId) || registry.any((e) => e['id'] == scriptId)) {
      throw '导入失败：脚本「${_scripts[scriptId]?.name ?? scriptId}」已存在';
    }
    _userScriptFile(dir, scriptId).writeAsStringSync(content, flush: true);
    // 名称优先级：手填 > @name > id（lx-music 同为脚本声明优先于生成名）
    final trimmedName = name.trim().isNotEmpty
        ? name.trim()
        : (meta.name.isNotEmpty ? meta.name : scriptId);
    registry.add({
      'id': scriptId,
      'name': trimmedName,
      'url': url?.trim() ?? '',
      'version': meta.version,
      'author': meta.author,
      'description': meta.description,
      'homepage': meta.homepage,
    });
    await _writeRegistry(registry);
    _scripts[scriptId] = LxScriptInfo(
      id: scriptId,
      name: trimmedName,
      builtin: false,
      url: url?.trim() ?? '',
      version: meta.version,
      author: meta.author,
      description: meta.description,
      homepage: meta.homepage,
    );
    appLog('lx: 新增自定义脚本[$scriptId] $trimmedName'
        '${meta.version.isEmpty ? '' : ' v${meta.version}'}'
        '（${content.length} 字符）');
    return scriptId;
  }

  /// 改名（内置与自定义统一入口）：自定义写注册表，内置写
  /// settings.lxScriptNames（清单默认名只在本会话之外存在）。
  Future<void> renameScript(String id, String name) async {
    final info = _scripts[id];
    if (info == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == info.name) return;
    info.name = trimmed;
    if (info.builtin) {
      final settings = activeSettings;
      if (settings == null) return;
      final map = settings.lxScriptNameMap();
      if (map[id] == trimmed) return;
      map[id] = trimmed;
      settings.lxScriptNames = [
        for (final entry in map.entries) ...[entry.key, entry.value],
      ];
      await settings.save();
      appLog('lx: 内置脚本[$id] 已改名「$trimmed」');
      return;
    }
    final registry = await _readRegistry();
    for (final entry in registry) {
      if (entry['id'] == id) entry['name'] = trimmed;
    }
    await _writeRegistry(registry);
  }

  /// 更新自定义脚本的来源 URL（内容更新由调用方另行处理）。
  Future<void> setUserScriptUrl(String id, String url) async {
    final info = _scripts[id];
    if (info == null || info.builtin) return;
    final trimmed = url.trim();
    if (trimmed == info.url) return;
    final registry = await _readRegistry();
    for (final entry in registry) {
      if (entry['id'] == id) entry['url'] = trimmed;
    }
    await _writeRegistry(registry);
    info.url = trimmed;
    appLog('lx: 自定义脚本[$id] 来源 URL 已更新');
  }

  /// 替换自定义脚本内容；若已加载则卸载，待下次懒加载取新内容。
  /// 同时按新内容重解析头部元信息（版本号随更新推进）并清除旧更新提醒。
  Future<void> updateUserScriptContent(String id, String content) async {
    final info = _scripts[id];
    if (info == null || info.builtin) return;
    final dir = await _userScriptsDir();
    _userScriptFile(dir, id).writeAsStringSync(content, flush: true);
    final meta = parseScriptMeta(content);
    info
      ..version = meta.version
      ..author = meta.author
      ..description = meta.description
      ..homepage = meta.homepage
      ..updateLog = ''
      ..updateUrl = '';
    if (meta.name.isNotEmpty && info.name.startsWith('u_')) {
      info.name = meta.name; // 自动名（未手填）跟随脚本声明
    }
    final registry = await _readRegistry();
    for (final entry in registry) {
      if (entry['id'] == id) {
        entry['name'] = info.name;
        entry['version'] = meta.version;
        entry['author'] = meta.author;
        entry['description'] = meta.description;
        entry['homepage'] = meta.homepage;
      }
    }
    await _writeRegistry(registry);
    await unloadScript(id);
    appLog('lx: 自定义脚本[$id] 内容已更新'
        '${meta.version.isEmpty ? '' : '（v${meta.version}）'}'
        '（${content.length} 字符）');
  }

  /// 删除自定义脚本（卸载 iframe + 删文件 + 出注册表）。
  Future<void> deleteUserScript(String id) async {
    final info = _scripts[id];
    if (info == null || info.builtin) return;
    await unloadScript(id);
    final dir = await _userScriptsDir();
    try {
      _userScriptFile(dir, id).deleteSync();
    } catch (_) {}
    final registry = await _readRegistry();
    registry.removeWhere((entry) => entry['id'] == id);
    await _writeRegistry(registry);
    _scripts.remove(id);
    appLog('lx: 自定义脚本[$id] 已删除');
  }

  /// 读取自定义脚本内容（编辑用）。
  static Future<String> readUserScriptContent(String id) async {
    final dir = await _userScriptsDir();
    final file = _userScriptFile(dir, id);
    if (!file.existsSync()) return '';
    return file.readAsStringSync();
  }

  /// 忽略脚本的更新提醒：清 Dart 侧展示，也清父页 entry（否则下一轮
  /// refreshStatus 又把同一条拉回来）。脚本重新初始化再上报会重新出现。
  Future<void> clearUpdateAlert(String id) async {
    final info = _scripts[id];
    if (info == null) return;
    info
      ..updateLog = ''
      ..updateUrl = '';
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.runJavaScript(
        '(function(){var e=window.__lxFrames[${jsonEncode(id)}];'
        'if(e){e.updateAlert=null;}})()',
      );
    } catch (_) {}
  }

  /// 卸载脚本 iframe 并复位状态（重载/删除/改内容前调用）。
  Future<void> unloadScript(String id) async {
    final controller = _controller;
    final info = _scripts[id];
    if (info != null) {
      info
        ..loading = false
        ..error = ''
        ..ready = false
        ..lastLog = ''
        ..sources = {};
    }
    if (controller == null) return;
    try {
      await controller.runJavaScript('window.__lxUnload(${jsonEncode(id)})');
    } catch (error) {
      appLog('lx: 脚本[$id] 卸载失败: $error');
    }
  }

  /// 卸载后重载（改内容/手动重试用）。
  Future<void> reloadScript(String id) async {
    await unloadScript(id);
    await loadScript(id);
  }

  void _onMessage(JavaScriptMessage message) {
    try {
      final value = jsonDecode(message.message) as Map<String, dynamic>;
      final id = value['id']?.toString() ?? '';
      final waiter = _waiters.remove(id);
      if (waiter == null || waiter.isCompleted) return;
      waiter.complete(value);
    } catch (error) {
      appLog('lx: 运行时消息解析失败: $error');
    }
  }

  /// 懒加载一个脚本（建 iframe；初始化几秒）。
  ///
  /// 就绪率现实：28 个第三方脚本顺序预热时，WebView 内容进程可能在
  /// 某个脚本（重脚本/内存压力）上整个崩掉——之后所有 iframe 零事件、
  /// 全部「初始化超时」。因此轮询期间每 ~3s 做一次 liveness 探针
  /// （window.__lxPing），无响应即重载 runtime.html 自愈，再把当前
  /// 脚本重新挂上。
  Future<void> loadScript(String id) async {
    final controller = _controller;
    final info = _scripts[id];
    if (controller == null || info == null || info.ready || info.loading) {
      return;
    }
    info.loading = true;
    try {
      await _mountScript(controller, id, info);
      // 等脚本 inited（第三方 API 冷启动慢，15s 折中）
      for (var i = 0; i < 75; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await refreshStatus();
        if (info.ready || info.error.isNotEmpty) break;
        // 零事件 + 探针无响应 → 页面死了：自愈后重挂 iframe 继续
        if (i % 15 == 14 && info.lastLog.isEmpty && await _healIfDead()) {
          final healed = _controller;
          if (healed != null) {
            await _mountScript(healed, id, info);
          }
        }
      }
      if (!info.ready && info.error.isEmpty) {
        // 超时也落成错误态：解析链据此跳过，避免每首都重试 10 秒
        info.error = '初始化超时';
      }
      if (!info.ready) {
        // 失败脚本卸掉 iframe 释放页面资源（状态保留在 Dart 侧）
        try {
          await controller.runJavaScript(
            'window.__lxUnload(${jsonEncode(id)})',
          );
        } catch (_) {}
      }
      appLog(
        info.ready
            ? 'lx: 脚本[$id] 就绪，源: ${info.sources.keys.join(",")}'
            : 'lx: 脚本[$id] 未就绪（${info.error.isEmpty ? "初始化超时" : info.error}）'
                  '${info.lastLog.isEmpty ? "" : " 最后事件: ${info.lastLog}"}',
      );
    } catch (error) {
      info.error = '$error';
      appLog('lx: 脚本[$id] 加载失败: $error');
    } finally {
      info.loading = false;
    }
  }

  DateTime? _lastHeal;

  /// 挂载脚本 iframe，连同元信息注入（frame.html 据此填充
  /// lx.currentScriptInfo，对齐 lx-music）。元信息来自导入时的头部解析
  /// （addUserScript / updateUserScriptContent 已回填）。
  Future<void> _mountScript(
    WebViewController controller,
    String id,
    LxScriptInfo info,
  ) async {
    final metaJson = jsonEncode({
      'name': info.name,
      'version': info.version,
      'author': info.author,
      'description': info.description,
      'homepage': info.homepage,
    });
    await controller.runJavaScript(
      'window.__lxLoad(${jsonEncode(id)}, ${jsonEncode(metaJson)})',
    );
  }

  /// WebView 是否还活着（window.__lxPing 探针；抛错也视为死）。
  Future<bool> _isAlive() async {
    final controller = _controller;
    if (controller == null || !_ready) return false;
    try {
      final raw = await controller.runJavaScriptReturningResult(
        'window.__lxPing ? "pong" : "dead"',
      );
      return raw.toString().contains('pong');
    } catch (_) {
      return false;
    }
  }

  /// 页面死了就重载 runtime.html；返回是否执行了（成功的）自愈。
  /// 重载会清掉所有 iframe——已就绪脚本状态一并复位，解析链会按需重挂。
  Future<bool> _healIfDead() async {
    if (await _isAlive()) return false;
    final last = _lastHeal;
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(seconds: 10)) {
      return false; // 自愈冷却：页面连崩时避免打转
    }
    _lastHeal = now;
    final controller = _controller;
    final base = SignerBridge.instance.baseUri;
    if (controller == null || base.isEmpty) return false;
    appLog('lx: 运行时探针无响应，重载 runtime.html 自愈');
    _ready = false;
    for (final info in _scripts.values) {
      info
        ..loading = false
        ..error = ''
        ..ready = false
        ..lastLog = ''
        ..sources = {};
    }
    try {
      await controller.loadRequest(Uri.parse('${base}lx/runtime.html'));
      for (var i = 0; i < 40 && !_ready; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      appLog(_ready ? 'lx: 运行时自愈完成（脚本状态已复位，按需重挂）' : 'lx: 运行时自愈后仍未就绪');
      return _ready;
    } catch (error) {
      appLog('lx: 运行时自愈失败: $error');
      return false;
    }
  }

  /// 刷新各脚本状态（iframe inited/error → sources/qualitys）。
  Future<void> refreshStatus() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final raw = await controller.runJavaScriptReturningResult(
        'JSON.stringify(window.__lxStatus() || {})',
      );
      var text = raw.toString();
      if (text.startsWith('"') && text.endsWith('"')) {
        text = jsonDecode(text) as String;
      }
      final map = jsonDecode(text) as Map<String, dynamic>;
      for (final entry in map.entries) {
        final info = _scripts[entry.key];
        if (info == null) continue;
        // 单个脚本的状态解析异常只影响它自己（历史教训：一个脚本上报
        // 异形字段曾让其后所有脚本全部读不到状态）。
        try {
          final value = entry.value as Map<String, dynamic>;
          info.error = value['error']?.toString() ?? '';
          info.ready = value['ready'] == true;
          info.lastLog = value['lastLog']?.toString() ?? '';
          // 脚本更新提醒（lx-music updateAlert 协议）：保留最新上报，
          // 处理后（一键更新/忽略）由对应入口清除
          final alert = value['updateAlert'];
          if (alert is Map) {
            final log = alert['log']?.toString() ?? '';
            final updateUrl = alert['updateUrl']?.toString() ?? '';
            if (log.isNotEmpty || updateUrl.isNotEmpty) {
              if (log != info.updateLog || updateUrl != info.updateUrl) {
                info
                  ..updateLog = log
                  ..updateUrl = updateUrl;
                appLog('lx: 脚本[${entry.key}] 上报更新提醒'
                    '${updateUrl.isEmpty ? '' : ' → $updateUrl'}');
              }
            }
          }
          final sources = value['sources'];
          if (sources is Map<String, dynamic> && info.ready) {
            // 规范形态：{kw: ['128k','320k',…]}（runtime.html __lxSourcesOf
            // 已做规范化）。此处再容错一层：info 对象形态取其 qualitys 字段。
            info.sources = sources.map((source, raw) {
              Iterable<dynamic> values;
              if (raw is List) {
                values = raw;
              } else if (raw is Map) {
                final inner = raw['qualitys'];
                if (inner is List) {
                  values = inner;
                } else if (inner is Map) {
                  values = [...inner.keys, ...inner.values];
                } else {
                  values = const [];
                }
              } else {
                values = const [];
              }
              const known = {'128k', '320k', 'flac', 'flac24bit'};
              return MapEntry(
                source,
                values.map((q) => q.toString()).where(known.contains).toList(),
              );
            });
          }
        } catch (error) {
          appLog('lx: 脚本[${entry.key}] 状态解析失败: $error');
        }
      }
    } catch (error) {
      // 页面未就绪/内容进程崩溃等。限频记录：探针会另行触发自愈。
      final now = DateTime.now();
      final last = _lastStatusThrow;
      if (last == null || now.difference(last) > const Duration(seconds: 30)) {
        _lastStatusThrow = now;
        appLog('lx: 状态刷新失败（页面疑似不可用）: $error');
      }
    }
  }

  DateTime? _lastStatusThrow;

  /// 取播放地址：脚本 musicUrl(source, songmid, quality)。
  /// 返回原始结果 {ok, result}——详情页测试需要失败原因。
  /// [name]/[singer] 透传给脚本的 musicInfo（部分脚本按歌名+歌手自搜）。
  Future<Map<String, dynamic>> musicUrlRaw(
    String scriptId,
    String source,
    String songmid,
    String quality, {
    String name = '',
    String singer = '',
  }) async {
    final controller = _controller;
    if (controller == null || !_ready) {
      appLog('lx: musicUrl[$scriptId] 跳过（运行时未就绪 ready=$_ready）');
      return {'ok': false, 'result': 'lx 运行时未就绪'};
    }
    final cbId = 'lx-${++_cbSeq}';
    final completer = Completer<Map<String, dynamic>>();
    _waiters[cbId] = completer;
    final script =
        'window.__lxMusicUrl(${jsonEncode(cbId)}, '
        '${jsonEncode(scriptId)}, ${jsonEncode(source)}, '
        '${jsonEncode(songmid)}, ${jsonEncode(quality)}, '
        '${jsonEncode(name)}, ${jsonEncode(singer)})';
    try {
      await controller.runJavaScript(script);
    } catch (error) {
      _waiters.remove(cbId);
      appLog('lx: musicUrl[$scriptId] 调度失败: $error');
      return {'ok': false, 'result': '调度失败: $error'};
    }
    return completer.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        _waiters.remove(cbId);
        appLog('lx: musicUrl[$scriptId $source $quality] 超时');
        return {'ok': false, 'result': '超时'};
      },
    );
  }

  /// 取播放地址（成功返回 http URL，失败返回 null）。
  Future<String?> musicUrl(
    String scriptId,
    String source,
    String songmid,
    String quality, {
    String name = '',
    String singer = '',
  }) async {
    final result = await musicUrlRaw(
      scriptId,
      source,
      songmid,
      quality,
      name: name,
      singer: singer,
    );
    if (result['ok'] == true) {
      final url = result['result']?.toString() ?? '';
      return url.startsWith('http') ? url : null;
    }
    return null;
  }

  /// App 免签曲库/搜索支持的平台（固定顺序罗列）。曲库平台与激活脚本
  /// 解耦：平台决定榜单/搜索维度，出链由脚本链按「激活脚本优先 →
  /// 其余就绪脚本回退」解析，不支持该平台的脚本自然跳过。
  static const searchSupportedPlatforms = ['kw', 'wy', 'kg', 'tx'];

  /// 按脚本 id 查注册表（未加载/不存在返回 null）。
  LxScriptInfo? scriptById(String id) => _scripts[id];

  /// 脚本声明的可用曲库平台（就绪后才有；交集免签搜索面，固定顺序）。
  List<String> platformsOfScript(LxScriptInfo script) {
    if (!script.ready) return const [];
    return [
      for (final platform in searchSupportedPlatforms)
        if (script.sources.containsKey(platform)) platform,
    ];
  }

  /// 激活脚本（settings.lxScript 指向且未停用/隐藏）；'' 或失效 → null
  /// （未选定脚本的聚合兜底模式）。
  LxScriptInfo? _activeScriptInfo() {
    final id = activeSettings?.lxScript ?? '';
    if (id.isEmpty) return null;
    final script = _scripts[id];
    if (script == null || !script.ready) return null;
    if (activeSettings?.lxDisabledScripts.contains(id) == true ||
        activeSettings?.lxHiddenScripts.contains(id) == true) {
      return null;
    }
    return script;
  }

  /// 平台实际可选音质：就绪且未停用脚本对该平台声明 qualitys 的并集
  /// （按 128k < 320k < flac < flac24bit 排序）。音质面板据此动态渲染，
  /// 不写死；激活具体脚本时收敛为该脚本的声明。无就绪脚本时回落全部
  /// 已知档位（与平台回落同哲学：冷启动预热未完成时选项不能空，
  /// 实际取不到的档位由解析链逐级回落兜底）。
  static const _qualityOrder = ['128k', '320k', 'flac', 'flac24bit'];

  List<String> availableQualities(String platform) {
    final active = _activeScriptInfo();
    if (active != null) {
      final qualitys = active.sources[platform] ?? const <String>[];
      if (qualitys.isNotEmpty) {
        return [
          for (final quality in _qualityOrder)
            if (qualitys.contains(quality)) quality,
        ];
      }
    }
    final skip = {
      ...?activeSettings?.lxDisabledScripts,
      ...?activeSettings?.lxHiddenScripts,
    };
    final declared = <String>{};
    for (final script in _scripts.values) {
      if (skip.contains(script.id)) continue;
      if (!script.ready) continue;
      declared.addAll(script.sources[platform] ?? const <String>[]);
    }
    if (declared.isEmpty) return List.of(_qualityOrder);
    return [
      for (final quality in _qualityOrder)
        if (declared.contains(quality)) quality,
    ];
  }

  /// 后台预热：只加载激活脚本（对齐 lx-music 单活模型——音源即脚本，
  /// 稳态只有 1 个 iframe；无激活脚本时不预热，其余脚本按需懒加载，
  /// 解析链在首攻时会等待加载）。
  Future<void> warmUp() async {
    final active = _activeScriptInfo();
    if (active == null) {
      appLog('lx: 预热跳过（未选定脚本，按需懒加载）');
      return;
    }
    if (!active.ready) {
      if (active.error.isNotEmpty) {
        await unloadScript(active.id); // 失败态先复位再重试一次
      }
      await loadScript(active.id);
    } else {
      // 已就绪：仍刷新一次状态（sources 可能刚上报）
      await refreshStatus();
    }
    appLog('lx: 预热完成（激活脚本「${active.name}」'
        '${active.ready ? "就绪" : "未就绪"}，其余脚本按需懒加载）');
  }
}

/// 1x1 常驻运行时视图。必须挂在**屏幕内**（离屏会被 iOS 节流），
/// 左上角 1px 对视觉无感知。
class LxRuntimeView extends StatefulWidget {
  const LxRuntimeView({super.key});

  @override
  State<LxRuntimeView> createState() => _LxRuntimeViewState();
}

class _LxRuntimeViewState extends State<LxRuntimeView> {
  @override
  void initState() {
    super.initState();
    unawaited(
      LxRuntime.instance.ensureStarted().then((_) {
        if (mounted) setState(() {});
        return LxRuntime.instance.warmUp();
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = LxRuntime.instance._controller;
    if (controller == null) return const SizedBox(width: 1, height: 1);
    return SizedBox(
      width: 1,
      height: 1,
      child: WebViewWidget(controller: controller),
    );
  }
}
