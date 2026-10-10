import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../core/api.dart';
import '../../core/lx_preset_sources.dart';
import '../../core/lx_runtime.dart';
import '../../core/lx_speed_test.dart';
import '../../core/source.dart';
import '../../core/speed.dart';
import '../../main.dart';

/// 取流脚本（原「其他音源」）：
///
/// * 洛雪取流脚本（推荐音源导入 / 手动添加，不随 App 注册），列表与
///   详情页共用同一套 UI（状态+延迟显示 / 启停 / 名称 / URL 编辑 / 测试 / 保存）；
/// * 排序：启用的在上、停用的在下；组内按端到端出链延迟升序；
/// * 对齐 lx-music「音源即脚本」：具体脚本可设为当前音源——lx 模式下
///   播放只用它出链（失败自动回落其余就绪脚本）；脚本同时是
///   「songmid → 播放地址」的解析通道，汽水试听回落也按列表顺序逐个
///   尝试出链。

/// 从 URL 下载脚本全文（添加页与详情页保存共用；4MB 上限防误用）。
Future<String> downloadScriptText(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 12));
    final response = await request.close().timeout(
      const Duration(seconds: 20),
    );
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > 4 * 1024 * 1024) throw '脚本超过 4MB，拒绝下载';
    }
    final text = utf8.decode(builder.takeBytes(), allowMalformed: true);
    if (text.trim().isEmpty) throw '下载内容为空';
    return text;
  } finally {
    client.close(force: true);
  }
}

class OtherSourcesPage extends StatefulWidget {
  const OtherSourcesPage({super.key, required this.onSettingsChanged});

  final VoidCallback onSettingsChanged;

  @override
  State<OtherSourcesPage> createState() => _OtherSourcesPageState();
}

class _OtherSourcesPageState extends State<OtherSourcesPage> {
  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    await LxRuntime.instance.ensureStarted();
    await LxRuntime.instance.refreshStatus();
    if (mounted) setState(() {});
  }

  Future<void> _openDetail(LxScriptInfo script) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ScriptDetailPage(scriptId: script.id, onDeleted: _refreshList),
      ),
    );
    await _prepare();
  }

  void _refreshList() {
    if (mounted) setState(() {});
  }

  Future<void> _addScript() async {
    final added = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const AddScriptPage()));
    if (added == true) {
      await _prepare();
    }
  }

  /// 组内排序：测过速且可用的按延迟升序在前，异常/未测的按
  /// （就绪 > 加载中 > 失败）再按名称垫底。
  int _bySpeed(LxScriptInfo a, LxScriptInfo b) {
    int speedMs(LxScriptInfo s) {
      final result = speedStore.of(lxSpeedKey(s.id));
      return (result != null && result.ok) ? result.ms : 1 << 30;
    }

    int stateRank(LxScriptInfo s) =>
        s.ready ? 0 : (s.loading ? 1 : (s.error.isNotEmpty ? 2 : 3));

    final bySpeed = speedMs(a).compareTo(speedMs(b));
    if (bySpeed != 0) return bySpeed;
    final byState = stateRank(a).compareTo(stateRank(b));
    if (byState != 0) return byState;
    return a.name.compareTo(b.name);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hidden = settings.lxHiddenScripts;
    final disabled = settings.lxDisabledScripts;
    final visible = LxRuntime.instance.scripts
        .where((s) => !hidden.contains(s.id))
        .toList();
    // 启用在上、停用在下；两组内部都按延迟排序
    final enabledScripts = visible
        .where((s) => !disabled.contains(s.id))
        .toList()
      ..sort(_bySpeed);
    final disabledScripts = visible
        .where((s) => disabled.contains(s.id))
        .toList()
      ..sort(_bySpeed);
    final readyCount = visible.where((s) => s.ready).length;
    return Scaffold(
      appBar: AppBar(title: const Text('取流脚本')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addScript,
        icon: const Icon(Icons.add),
        label: const Text('添加自定义脚本'),
      ),
      body: ListenableBuilder(
        listenable: speedStore,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 96),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Text('详情', style: Theme.of(context).textTheme.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                '洛雪取流脚本（对齐 lx-music 用户脚本：不随 App 注册，'
                '从「添加自定义脚本 → 推荐音源」导入或手动添加）。'
                '选定脚本即播放音源——播放只用它出链（失败自动回退其余'
                '就绪脚本）。行尾开关启停；音质档位跟随「设置 → 音质」'
                '（flac → 320k → 128k 逐级尝试）。',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Text(
                '已启用（${enabledScripts.length}）· $readyCount 就绪',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            ...enabledScripts.map(_scriptTile),
            if (disabledScripts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Text(
                  '已停用（${disabledScripts.length}）',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ...disabledScripts.map(_scriptTile),
          ],
        ),
      ),
    );
  }

  /// 手动启停（列表行尾开关；详情页开关同一逻辑）。
  Future<void> _toggle(String scriptId, bool enabled) async {
    setState(() {
      settings.lxDisabledScripts = enabled
          ? settings.lxDisabledScripts
                .where((item) => item != scriptId)
                .toList()
          : [
              ...settings.lxDisabledScripts.where(
                (item) => item != scriptId,
              ),
              scriptId,
            ];
    });
    await settings.save();
  }

  Widget _scriptTile(LxScriptInfo script) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = !settings.lxDisabledScripts.contains(script.id);
    final speed = speedStore.of(lxSpeedKey(script.id));
    final status = script.ready
        ? '就绪 · ${script.sources.keys.join("/")} · '
              '${script.sources.values.expand((q) => q).toSet().join("/")}'
        : script.loading
        ? '加载中…'
        : script.error.isNotEmpty
        ? '失败: ${script.error}'
        : '未加载';
    return ListTile(
      leading: Icon(
        script.ready
            ? Icons.extension
            : script.error.isNotEmpty
            ? Icons.extension_off
            : Icons.hourglass_empty,
        size: 22,
        color: script.ready ? scheme.primary : scheme.outline,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              script.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: enabled
                  ? null
                  : TextStyle(color: scheme.outline),
            ),
          ),
          if (settings.sourceMode == 'lx' &&
              settings.lxScript == script.id) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '当前音源',
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
          if (script.hasUpdateAlert) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '可更新',
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
          if (!enabled) ...[
            const SizedBox(width: 6),
            Text('已停用', style: TextStyle(fontSize: 11, color: scheme.outline)),
          ],
        ],
      ),
      subtitle: Text(
        status,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (speed != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: speed.ok
                    ? Colors.green.withValues(alpha: 0.12)
                    : scheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                speed.ok ? '${speed.ms}ms' : '异常',
                style: TextStyle(
                  fontSize: 11,
                  color: speed.ok
                      ? Colors.green.shade700
                      : scheme.onErrorContainer,
                ),
              ),
            ),
          // 手动启停：停用后不参与解析链（不再由测速自动改动）
          Switch(
            value: enabled,
            onChanged: (value) => _toggle(script.id, value),
          ),
        ],
      ),
      onTap: () => _openDetail(script),
    );
  }
}

/// 单个脚本详情（内置与自定义共用同一页面，样式对齐 SodaM 音源详情）：
/// 状态+延迟显示、启用开关、名称/脚本 URL 编辑、测试、保存；
/// 另有重新加载、编辑内容/删除（自定义）或隐藏（内置）。
class ScriptDetailPage extends StatefulWidget {
  const ScriptDetailPage({super.key, required this.scriptId, this.onDeleted});

  final String scriptId;
  final VoidCallback? onDeleted;

  @override
  State<ScriptDetailPage> createState() => _ScriptDetailPageState();
}

class _ScriptDetailPageState extends State<ScriptDetailPage> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  bool _busy = false;
  bool _saving = false;
  String? _testResult;
  bool _testOk = false;

  LxScriptInfo? get _info {
    for (final script in LxRuntime.instance.scripts) {
      if (script.id == widget.scriptId) return script;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final info = _info;
    _name = TextEditingController(text: info?.name ?? '');
    _url = TextEditingController(text: info?.url ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _toggle(bool enabled) async {
    setState(() {
      settings.lxDisabledScripts = enabled
          ? settings.lxDisabledScripts
                .where((item) => item != widget.scriptId)
                .toList()
          : [
              ...settings.lxDisabledScripts.where(
                (item) => item != widget.scriptId,
              ),
              widget.scriptId,
            ];
    });
    await settings.save();
  }

  /// 端到端测试：kw/wy 平台搜索「晴天」→ 脚本 musicUrl 出链。
  /// 不支持 kw/wy 的脚本说明原因（App 只实现了这两个平台的免签搜索）。
  Future<void> _test() async {
    final info = _info;
    if (info == null || _busy) return;
    setState(() {
      _busy = true;
      _testResult = '测试中…';
    });
    try {
      if (!info.ready) {
        if (info.error.isNotEmpty) {
          // 失败过的先复位重载（错误态会被解析链跳过）
          await LxRuntime.instance.unloadScript(info.id);
        }
        await LxRuntime.instance.loadScript(info.id);
        await LxRuntime.instance.refreshStatus();
        if (mounted) setState(() {});
      }
      if (!info.ready) {
        setState(() {
          _testOk = false;
          _testResult =
              '脚本未就绪：'
              '${info.error.isNotEmpty ? info.error : (info.lastLog.isEmpty ? "初始化超时" : info.lastLog)}';
        });
        return;
      }
      String? platform;
      for (final candidate in LxRuntime.searchSupportedPlatforms) {
        if (info.sources.containsKey(candidate)) {
          platform = candidate;
          break;
        }
      }
      if (platform == null) {
        setState(() {
          _testOk = false;
          _testResult = info.sources.isEmpty
              ? '脚本初始化成功但未声明任何可用平台/音质（不会参与解析链）'
              : '该脚本只支持 ${info.sources.keys.join("/")} 平台，'
                    '而 App 仅能搜索 kw/wy，无法端到端验证（解析链也不会用到它）';
        });
        return;
      }
      String? quality;
      for (final candidate in ['128k', '320k', 'flac', 'flac24bit']) {
        if (info.sources[platform]!.contains(candidate)) {
          quality = candidate;
          break;
        }
      }
      final results = await Api.searchPlatform(platform, '周杰伦 晴天');
      String? songmid;
      for (final result in results) {
        final value = result['songmid']?.toString() ?? '';
        if (value.isNotEmpty) {
          songmid = value;
          break;
        }
      }
      if (songmid == null) {
        setState(() {
          _testOk = false;
          _testResult = '$platform 平台搜索无结果（搜索链路异常，与脚本无关）';
        });
        return;
      }
      final stopwatch = Stopwatch()..start();
      final raw = await LxRuntime.instance.musicUrlRaw(
        info.id,
        platform,
        songmid,
        quality ?? '128k',
        name: '晴天',
        singer: '周杰伦',
      );
      final ms = stopwatch.elapsedMilliseconds;
      final url = raw['result']?.toString() ?? '';
      final okUrl = raw['ok'] == true && url.startsWith('http');
      // 出链延迟回写 speedStore：列表页延迟徽标与按延迟排序共用
      speedStore.update(
        lxSpeedKey(info.id),
        SpeedResult(ms: ms, text: okUrl ? '可用' : '出链失败', ok: okUrl),
      );
      // 测试通过 = 脚本已恢复：清掉选定脚本首攻熔断（若它是当前音源）
      if (okUrl) Api.resetActiveScriptFuse();
      setState(() {
        _testOk = okUrl;
        _testResult = _testOk
            ? '可用：$platform ${quality ?? "128k"} 出链 ${ms}ms\n$url'
            : '出链失败（${ms}ms）：$url';
      });
    } catch (error) {
      setState(() {
        _testOk = false;
        _testResult = '测试失败：$error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _testResult = null;
    });
    await LxRuntime.instance.reloadScript(widget.scriptId);
    await LxRuntime.instance.refreshStatus();
    // 手动重载即一次重新初始化：给选定脚本首攻重新机会
    Api.resetActiveScriptFuse();
    if (mounted) setState(() => _busy = false);
  }

  /// 一键更新：按脚本上报的 updateUrl 下载新版并替换内容
  /// （updateUserScriptContent 会重解析头部元信息并清掉提醒）。
  Future<void> _updateByAlert() async {
    final info = _info;
    if (info == null || _busy || info.updateUrl.isEmpty) return;
    setState(() => _busy = true);
    try {
      final content = await downloadScriptText(info.updateUrl);
      await LxRuntime.instance.updateUserScriptContent(info.id, content);
      await LxRuntime.instance.setUserScriptUrl(info.id, info.updateUrl);
      // 新版脚本待重新初始化：清首攻熔断，给它机会
      Api.resetActiveScriptFuse();
      unawaited(_warm(info.id));
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(
              '已更新到${info.version.isEmpty ? '最新版' : ' v${info.version}'}，'
              '正在重新初始化',
            ),
          ));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('更新失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 忽略本次更新提醒（脚本重新初始化再上报会重新出现）。
  Future<void> _ignoreUpdateAlert() async {
    await LxRuntime.instance.clearUpdateAlert(widget.scriptId);
    if (mounted) setState(() {});
  }

  /// 设为当前音源（lx 模式激活此脚本；播放只用它出链，失败自动回落）。
  Future<void> _setAsSource() async {
    await sourceStore.switchTo('lx');
    await sourceStore.switchScript(widget.scriptId);
    // 重新选定即重新初始化：清掉该脚本可能存在的首攻熔断。
    Api.resetActiveScriptFuse();
    if (!mounted) return;
    setState(() {});
    final name = _info?.name ?? '';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('已设为当前音源「$name」，播放将只用此脚本取流'),
        duration: const Duration(seconds: 1),
      ));
  }

  /// 保存：名称（内置/自定义都支持）；自定义脚本 URL 变更时自动重新
  /// 下载脚本内容并替换（下载失败则整体不保存，内容不动）。
  Future<void> _save() async {
    final info = _info;
    if (info == null || _saving) return;
    setState(() => _saving = true);
    try {
      await LxRuntime.instance.renameScript(info.id, _name.text);
      {
        final url = _url.text.trim();
        if (url != info.url) {
          if (url.isEmpty) {
            await LxRuntime.instance.setUserScriptUrl(info.id, '');
          } else {
            final content = await downloadScriptText(url);
            await LxRuntime.instance.updateUserScriptContent(info.id, content);
            await LxRuntime.instance.setUserScriptUrl(info.id, url);
            // 内容已替换（脚本被卸载），后台重新初始化
            unawaited(_warm(info.id));
          }
        }
      }
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('已保存')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('保存失败：$error（内容未改动）')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 后台重新初始化（保存新内容后调用，不阻塞表单）。
  Future<void> _warm(String id) async {
    await LxRuntime.instance.loadScript(id);
    if (mounted) setState(() {});
  }

  Future<void> _editContent() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ScriptContentEditorPage(scriptId: widget.scriptId),
      ),
    );
    if (saved == true && mounted) {
      await _reload(); // 保存即卸载，这里立即用新内容重新初始化
    }
  }

  Future<void> _delete() async {
    final info = _info;
    if (info == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除「${info.name}」？'),
        content: const Text('脚本与配置将一并删除，不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await LxRuntime.instance.deleteUserScript(widget.scriptId);
    setState(() {
      settings.lxDisabledScripts = settings.lxDisabledScripts
          .where((item) => item != widget.scriptId)
          .toList();
    });
    await settings.save();
    widget.onDeleted?.call();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = _info;
    if (info == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('脚本详情')),
        body: const Center(child: Text('脚本不存在（可能已被删除）')),
      );
    }
    final enabled = !settings.lxDisabledScripts.contains(info.id);
    final speed = speedStore.of(lxSpeedKey(info.id));
    return Scaffold(
      appBar: AppBar(title: Text(info.name)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Text('状态', style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      info.ready
                          ? Icons.check_circle
                          : info.error.isNotEmpty
                          ? Icons.error_outline
                          : Icons.hourglass_empty,
                      size: 18,
                      color: info.ready
                          ? Colors.green.shade700
                          : info.error.isNotEmpty
                          ? scheme.error
                          : scheme.outline,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        info.ready
                            ? '就绪 · ${info.sources.keys.join(" / ")} · '
                                  '${info.sources.values.expand((q) => q).toSet().join(" / ")}'
                            : info.loading
                            ? '加载中…（初始化最长 15 秒）'
                            : info.error.isNotEmpty
                            ? '失败：${info.error}'
                            : '未加载（首次使用或测试时自动加载）',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    if (speed != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: speed.ok
                              ? Colors.green.withValues(alpha: 0.12)
                              : scheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          speed.ok ? '${speed.ms}ms' : '异常',
                          style: TextStyle(
                            fontSize: 11,
                            color: speed.ok
                                ? Colors.green.shade700
                                : scheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (info.lastLog.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '生命周期：${info.lastLog}',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                ],
                if (info.version.isNotEmpty ||
                    info.author.isNotEmpty ||
                    info.homepage.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    [
                      if (info.version.isNotEmpty) 'v${info.version}',
                      if (info.author.isNotEmpty) info.author,
                      if (info.homepage.isNotEmpty) info.homepage,
                    ].join(' · '),
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          // 脚本上报的更新提醒（lx-music updateAlert 协议）
          if (info.hasUpdateAlert) ...[
            const SizedBox(height: 4),
            Card(
              margin: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              color: scheme.tertiaryContainer.withValues(alpha: 0.45),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.system_update_alt,
                            size: 16, color: scheme.tertiary),
                        const SizedBox(width: 6),
                        Text('脚本有新版本',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    if (info.updateLog.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        info.updateLog,
                        style: const TextStyle(fontSize: 12),
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        if (info.updateUrl.isNotEmpty)
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: _busy ? null : _updateByAlert,
                              icon: _busy
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.download, size: 18),
                              label: const Text('一键更新'),
                            ),
                          ),
                        if (info.updateUrl.isNotEmpty)
                          const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _ignoreUpdateAlert,
                            child: const Text('忽略'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            secondary: const Icon(Icons.power_settings_new),
            title: const Text('参与解析链'),
            subtitle: const Text(
              '停用后试听回落不再尝试该脚本',
              style: TextStyle(fontSize: 12),
            ),
            value: enabled,
            onChanged: _toggle,
          ),
          // 设为当前音源（对齐 lx-music：音源即脚本，播放只用它出链）
          Builder(
            builder: (context) {
              final isCurrentSource =
                  settings.sourceMode == 'lx' &&
                      settings.lxScript == info.id;
              return ListTile(
                leading: const Icon(Icons.album),
                title: const Text('设为当前音源'),
                subtitle: Text(
                  isCurrentSource
                      ? '已是当前音源（播放只用此脚本取流）'
                      : '切到「其他音源」，播放只用此脚本出链'
                          '（失败自动回退其它脚本）',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: isCurrentSource
                    ? Icon(Icons.check_circle, color: scheme.primary)
                    : const Icon(Icons.chevron_right),
                onTap: isCurrentSource ? null : _setAsSource,
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Text('编辑', style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: '名称',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '脚本 URL（修改保存后自动重新下载）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _test,
                        icon: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.speed, size: 18),
                        label: const Text('测试'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save_outlined, size: 18),
                        label: const Text('保存'),
                      ),
                    ),
                  ],
                ),
                if (_testResult != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _testResult!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _testOk ? Colors.green.shade700 : scheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('重新加载'),
            subtitle: const Text(
              '复位状态并重新初始化（改内容/失败重试后用）',
              style: TextStyle(fontSize: 12),
            ),
            trailing: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _busy ? null : _reload,
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('编辑脚本内容'),
            subtitle: const Text(
              '粘贴新版脚本保存后自动重载',
              style: TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editContent,
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: scheme.error),
            title: Text('删除', style: TextStyle(color: scheme.error)),
            subtitle: const Text(
              '脚本文件与配置一并删除',
              style: TextStyle(fontSize: 12),
            ),
            onTap: _delete,
          ),
        ],
      ),
    );
  }
}

/// 添加自定义脚本：推荐音源（随 App 打包的原内置源 + 社区源）测试/导入
/// + 名称 + 脚本内容（粘贴或从 URL 下载）。
///
/// 对齐 lx-music：脚本不随 App 注册——「测试」临时导入并端到端验证
/// （加载→搜索→出链→直链探测，完成后自动清理），「导入」才真正落库。
class AddScriptPage extends StatefulWidget {
  const AddScriptPage({super.key});

  @override
  State<AddScriptPage> createState() => _AddScriptPageState();
}

/// 打包推荐源（assets/lx/manifest.json 条目，内容在 assets/lx-sources/）。
typedef BundledPreset = ({String id, String file, String name});

class _AddScriptPageState extends State<AddScriptPage> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _content = TextEditingController();
  bool _downloading = false;
  bool _saving = false;

  List<BundledPreset> _bundled = [];
  bool _bundledLoading = true;

  /// 正在操作的行（null = 空闲；导入/测试同时只允许一个）。
  String? _busyKey;

  /// 行测试结果（key = 打包 id / 推荐源 URL）。
  final Map<String, LxScriptTestResult> _results = {};

  @override
  void initState() {
    super.initState();
    unawaited(_loadBundled());
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _loadBundled() async {
    try {
      final text = await rootBundle.loadString('assets/lx/manifest.json');
      final list = jsonDecode(text) as List;
      _bundled = [
        for (final item in list)
          (
            id: item['id']?.toString() ?? '',
            file: item['file']?.toString() ?? '',
            name: item['name']?.toString() ?? '',
          ),
      ].where((e) => e.id.isNotEmpty && e.file.isNotEmpty).toList();
    } catch (_) {}
    if (mounted) setState(() => _bundledLoading = false);
  }

  bool _imported(String key) {
    if (key.startsWith('http')) {
      return LxRuntime.instance.scripts.any((s) => s.url == key);
    }
    return LxRuntime.instance.scriptById(key) != null;
  }

  /// 后台初始化新脚本（导入后立即拉起，音源页/解析链即可用）。
  Future<void> _warm(String id) async {
    await LxRuntime.instance.ensureStarted();
    await LxRuntime.instance.loadScript(id);
    if (mounted) setState(() {});
  }

  /// 导入打包推荐源：读资产内容 → addUserScript（沿用清单 id，升级前后
  /// 同一源的选择不丢）→ 后台预热。离线可导入（不下载）。
  Future<void> _importBundled(BundledPreset preset) async {
    if (_busyKey != null) return;
    setState(() => _busyKey = preset.id);
    try {
      final content = await rootBundle
          .loadString('assets/lx-sources/${preset.file}')
          .timeout(const Duration(seconds: 5));
      await LxRuntime.instance.addUserScript(
        preset.name,
        content,
        id: preset.id,
      );
      unawaited(_warm(preset.id));
      if (mounted) {
        setState(() {}); // 刷新「已导入」标记
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('已导入「${preset.name}」，正在初始化')),
          );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('导入失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  /// 导入社区推荐源（URL 下载）。
  Future<void> _importPreset(LxPresetSource preset) async {
    if (_busyKey != null) return;
    setState(() => _busyKey = preset.url);
    try {
      final content = await downloadScriptText(preset.url);
      final id = await LxRuntime.instance.addUserScript(
        preset.name,
        content,
        url: preset.url,
      );
      unawaited(_warm(id));
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('已导入「${preset.name}」，正在初始化')),
          );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('导入失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  /// 测试打包推荐源：已导入 → 就地测试；未导入 → 临时导入（t_ 前缀）→
  /// 测试 → 自动清理（保持「未导入」原状）。
  Future<void> _testBundled(BundledPreset preset) async {
    await _testRow(
      key: preset.id,
      displayName: preset.name,
      resolve: () async {
        final existing = LxRuntime.instance.scriptById(preset.id);
        if (existing != null) return (existing.id, false);
        final content = await rootBundle
            .loadString('assets/lx-sources/${preset.file}')
            .timeout(const Duration(seconds: 5));
        final tempId =
            await LxRuntime.instance.addUserScript(preset.name, content, id: 't_${preset.id}');
        return (tempId, true);
      },
    );
  }

  /// 测试社区推荐源：按 URL 找已导入的，找不到临时下载导入再清理。
  Future<void> _testPreset(LxPresetSource preset) async {
    await _testRow(
      key: preset.url,
      displayName: preset.name,
      resolve: () async {
        for (final script in LxRuntime.instance.scripts) {
          if (script.url == preset.url) return (script.id, false);
        }
        final content = await downloadScriptText(preset.url);
        final tempId = await LxRuntime.instance.addUserScript(
          preset.name,
          content,
          url: preset.url,
        );
        return (tempId, true);
      },
    );
  }

  /// 行测试共用编排：[resolve] 返回（测试目标脚本 id, 是否临时导入）。
  Future<void> _testRow({
    required String key,
    required String displayName,
    required Future<(String, bool)> Function() resolve,
  }) async {
    if (_busyKey != null) return;
    setState(() => _busyKey = key);
    try {
      final (scriptId, temp) = await resolve();
      final result = await LxScriptTest.testScript(scriptId);
      if (temp) {
        await LxRuntime.instance.deleteUserScript(scriptId);
      } else {
        // 就地测试可能改变了脚本状态（失败重载），刷新列表页数据
        await LxRuntime.instance.refreshStatus();
      }
      if (mounted) setState(() => _results[key] = result);
    } catch (error) {
      if (mounted) {
        setState(
          () => _results[key] = LxScriptTestResult(
            ok: false,
            ms: 0,
            text: '测试失败：$error',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Widget _rowButtons({
    required String key,
    required VoidCallback onTest,
    required VoidCallback? onImport,
    required bool imported,
  }) {
    final busy = _busyKey == key;
    if (busy) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          onPressed: _busyKey != null ? null : onTest,
          child: const Text('测试'),
        ),
        imported
            ? Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  '已导入',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              )
            : TextButton(
                onPressed: _busyKey != null ? null : onImport,
                child: const Text('导入'),
              ),
      ],
    );
  }

  Widget _resultLine(String key) {
    final result = _results[key];
    if (result == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        result.ok ? '可用 ${result.ms}ms' : result.text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          color: result.ok ? Colors.green.shade700 : scheme.error,
        ),
      ),
    );
  }

  Widget _bundledTile(BundledPreset preset) {
    final scheme = Theme.of(context).colorScheme;
    final imported = _imported(preset.id);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        imported ? Icons.check_circle : Icons.archive_outlined,
        size: 22,
        color: imported ? Colors.green.shade700 : scheme.primary,
      ),
      title: Text(
        preset.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '原内置源 · 随 App 打包，离线导入',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11),
          ),
          _resultLine(preset.id),
        ],
      ),
      trailing: _rowButtons(
        key: preset.id,
        onTest: () => _testBundled(preset),
        onImport: () => _importBundled(preset),
        imported: imported,
      ),
    );
  }

  Widget _presetTile(LxPresetSource preset) {
    final scheme = Theme.of(context).colorScheme;
    final imported = _imported(preset.url);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        imported ? Icons.check_circle : Icons.cloud_download_outlined,
        size: 22,
        color: imported ? Colors.green.shade700 : scheme.primary,
      ),
      title: Text(
        preset.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            preset.note,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
          _resultLine(preset.url),
        ],
      ),
      trailing: _rowButtons(
        key: preset.url,
        onTest: () => _testPreset(preset),
        onImport: () => _importPreset(preset),
        imported: imported,
      ),
    );
  }

  Future<void> _download() async {
    final target = _url.text.trim();
    if (target.isEmpty || _downloading) return;
    setState(() => _downloading = true);
    try {
      final text = await downloadScriptText(target);
      _content.text = text;
      // 头部注释声明优先（对齐 lx-music：@name/@version 是脚本身份），
      // 再退回 URL 文件名
      final meta = parseScriptMeta(text);
      if (_name.text.trim().isEmpty) {
        _name.text = meta.name.isNotEmpty
            ? meta.name
            : target.split('/').last.replaceAll(RegExp(r'\.js$'), '');
      }
      if (mounted) {
        final versionHint = meta.version.isEmpty ? '' : '（v${meta.version}）';
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                '已下载 ${text.length} 字符$versionHint，请检查后保存',
              ),
            ),
          );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('下载失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_content.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('脚本内容不能为空')));
      return;
    }
    setState(() => _saving = true);
    try {
      final id = await LxRuntime.instance.addUserScript(
        _name.text,
        _content.text,
        url: _url.text,
      );
      unawaited(_warm(id));
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('已添加，可在详情页测试')));
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('保存失败：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('添加自定义脚本')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('推荐音源 · 随 App 打包', style: Theme.of(context).textTheme.titleSmall),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              '原 28 个内置源（pdone / guoyue 社区项目）已全部改为按需导入'
              '（对齐 lx-music：App 不注册任何音源脚本）。「测试」临时'
              '导入并端到端验证（加载→出链→直链可达，完成后自动清理），'
              '挑可用的再「导入」。离线可用。',
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
          ),
          if (_bundledLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ..._bundled.map(_bundledTile),
          const Divider(height: 32),
          Text('推荐音源 · 社区源', style: Theme.of(context).textTheme.titleSmall),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              '聚合自 GitHub/Gitee 等社区的开源洛雪音源项目（2026-10 实测'
              '可用，去重后保留 6 个）。导入需在线下载；第三方源随时可能'
              '失效，导入失败可稍后重试。',
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
          ),
          ...kPresetLxSources.map(_presetTile),
          const Divider(height: 32),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '名称（如 我的酷我源）',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '脚本 URL（可选，如 https://…/kw.js）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _downloading ? null : _download,
                child: _downloading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('下载'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _content,
            maxLines: null,
            minLines: 12,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              labelText: '脚本内容（lx-music 用户自定义音源 JS 全文）',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '协议与 lx-music 桌面版自定义音源一致：脚本内通过 '
            'lx.on(lx.EVENT_NAMES.request, …) 注册 musicUrl 处理器并发送 '
            'inited。不支持的平台/音质会在加载后标注。',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
    );
  }
}

/// 自定义脚本内容编辑器（保存后自动卸载，待懒加载取新内容）。
class ScriptContentEditorPage extends StatefulWidget {
  const ScriptContentEditorPage({super.key, required this.scriptId});

  final String scriptId;

  @override
  State<ScriptContentEditorPage> createState() =>
      _ScriptContentEditorPageState();
}

class _ScriptContentEditorPageState extends State<ScriptContentEditorPage> {
  late final TextEditingController _controller;
  bool _saving = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    LxRuntime.readUserScriptContent(widget.scriptId).then((content) {
      _controller.text = content;
      if (mounted) {
        setState(() => _loaded = true);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await LxRuntime.instance.updateUserScriptContent(
        widget.scriptId,
        _controller.text,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('已保存，正在重新加载…')));
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('保存失败：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('编辑脚本内容')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: '脚本 JS 全文',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('保存并重载'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
