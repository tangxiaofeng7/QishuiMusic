import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/lx_catalog.dart';
import '../../core/lx_runtime.dart';
import '../../core/models.dart';
import '../../core/mine_cache.dart';
import '../../core/source.dart';
import '../../core/speed.dart';
import '../../core/store.dart';
import '../../main.dart';
import '../../core/lx_speed_test.dart';
import 'lx_sources_page.dart';

/// 音源：播放音源并列单选（对齐 lx-music-desktop 的「音源切换」）。
///
/// * 汽水账号（默认）：登录账号取流 + 内置签名服务实现音质限免
///   （免费曲全景声/录音室/无损全档），VIP 曲按账号权益，试听档可
///   回落外部整曲；
/// * 酷我 / 网易云：平台曲库（免签搜索）+ 洛雪脚本链取流整曲。
///   同一时间仅一个音源生效；对齐 lx-music「音源即脚本」：选定具体
///   脚本后播放只用它取流（失败自动回退其余就绪脚本）。取流脚本
///   从「管理取流脚本 → 推荐音源」按需导入，不随 App 注册。
class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key, required this.onSettingsChanged});

  final VoidCallback onSettingsChanged;

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  int _lxReady = 0;
  int _lxTotal = 0;
  AccountInfo? _account;

  @override
  void initState() {
    super.initState();
    _refreshLx();
    _loadAccount();
  }

  /// 账号信息（VIP 状态展示）：先读缓存立即上屏，再后台拉最新。
  Future<void> _loadAccount() async {
    if (!settings.hasCookie) return;
    final cached = await MineCache.load();
    if (cached?.account != null && mounted) {
      setState(() => _account = cached!.account);
    }
    try {
      final account = await Api.account();
      if (mounted) setState(() => _account = account);
    } catch (_) {
      // 离线等场景保留缓存值即可
    }
  }

  Future<void> _refreshLx() async {
    await LxRuntime.instance.ensureStarted();
    await LxRuntime.instance.refreshStatus();
    if (mounted) {
      setState(() {
        final hidden = settings.lxHiddenScripts;
        final visible = LxRuntime.instance.scripts.where(
          (s) => !hidden.contains(s.id),
        );
        _lxTotal = visible.length;
        _lxReady = visible.where((s) => s.ready).length;
      });
    }
  }

  /// 音源选择：'default' = 汽水账号；其他 = 脚本 id（对齐 lx-music，
  /// 音源即脚本，无聚合模式）。
  Future<void> _select(String value) async {
    if (value == 'default') {
      await sourceStore.switchTo('default');
    } else {
      // 统一走 sourceStore：持久化 + 重建 Rust 会话 + 广播
      // （首页/发现/搜索立即换装对应音源的内容形态）
      await sourceStore.switchTo('lx');
      await sourceStore.switchScript(value);
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已切换到「${_sourceName(value)}」，播放只用此脚本取流'),
          duration: const Duration(seconds: 1),
        ),
      );
  }

  static String _sourceName(String value) => switch (value) {
    'default' => '汽水账号',
    _ => LxRuntime.instance.scriptById(value)?.name ?? value,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isLx = settings.sourceMode == 'lx';
    // 其他音源 = 取流脚本（对齐 lx-music「音源即脚本」，不写死）：
    // 就绪且有可用平台的脚本按测速延迟排列。
    final hidden = settings.lxHiddenScripts;
    final disabled = settings.lxDisabledScripts;
    final readyScripts = LxRuntime.instance.scripts
        .where((s) =>
            !hidden.contains(s.id) &&
            !disabled.contains(s.id) &&
            s.ready &&
            LxRuntime.instance.platformsOfScript(s).isNotEmpty)
        .toList()
      ..sort((a, b) {
        int ms(LxScriptInfo s) {
          final result = speedStore.of(lxSpeedKey(s.id));
          return result != null && result.ok ? result.ms : 1 << 30;
        }
        return ms(a).compareTo(ms(b));
      });
    final activeScript = settings.lxScript;
    // 激活脚本未就绪（冷启动校验窗口）或校验失败时固定置顶显示，
    // 避免用户以为已选音源丢失
    final activeInfo = activeScript.isEmpty
        ? null
        : LxRuntime.instance.scriptById(activeScript);
    final activePending = activeInfo != null &&
        !hidden.contains(activeScript) &&
        !disabled.contains(activeScript) &&
        !readyScripts.any((s) => s.id == activeScript);
    // 曲库平台与激活脚本解耦：免签曲库/搜索支持的平台全部可选，
    // 出链时脚本链自动跳过不支持当前平台的脚本。
    final platforms = LxRuntime.searchSupportedPlatforms;
    String scriptSubtitle(LxScriptInfo script) {
      final names =
          LxRuntime.instance.platformsOfScript(script).map(lxPlatformName);
      return [
        names.join('/'),
        if (script.version.isNotEmpty) 'v${script.version}',
      ].join(' · ');
    }

    return Scaffold(
      appBar: AppBar(title: const Text('音源')),
      body: ListenableBuilder(
        listenable: speedStore,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                '播放音源（同一时间仅一个生效，点按切换）',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            _SourceTile(
              icon: Icons.account_circle,
              title: '汽水账号',
              subtitle: !settings.hasCookie
                  ? '未登录（免费曲可播）'
                  : (_account?.vip == true
                        ? '${_account?.nickname ?? "已登录"} · VIP 会员 · 音质限免'
                        : '${_account?.nickname ?? "已登录"} · 非 VIP（VIP 曲试听）· 音质限免'),
              selected: settings.sourceMode == 'default',
              speed: speedStore.of('default'),
              onSelect: () => _select('default'),
              onDetail: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SodaAccountSourcePage(
                    onSettingsChanged: widget.onSettingsChanged,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text('其他音源 · 取流脚本',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            if (activePending)
              _SourceTile(
                icon: Icons.extension,
                title: activeInfo.name,
                subtitle: activeInfo.error.isEmpty
                    ? '当前音源 · 正在校验初始化，就绪后自动可用（点按立即激活）'
                    : '当前音源 · 校验未通过：${activeInfo.error}（点按重试）',
                selected: true,
                speed: null,
                // 未就绪也允许激活：切 lx 模式并立即初始化（否则默认
                // 模式下无人加载它，用户被锁在汽水音源）
                onSelect: () async {
                  await sourceStore.switchTo('lx');
                  sourceStore.warmActiveScript();
                  if (mounted) setState(() {});
                },
                onDetail: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ScriptDetailPage(scriptId: activeInfo.id),
                  ),
                ),
              ),
            for (final script in readyScripts)
              _SourceTile(
                icon: Icons.extension,
                title: script.name,
                subtitle: scriptSubtitle(script),
                selected: isLx && activeScript == script.id,
                speed: isLx && activeScript == script.id
                    ? speedStore.of(lxSpeedKey(script.id))
                    : null,
                onSelect: () => _select(script.id),
                onDetail: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ScriptDetailPage(scriptId: script.id),
                  ),
                ),
              ),
            if (readyScripts.isEmpty && activeInfo == null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Text(
                  '暂无取流脚本：到下方「管理取流脚本 → 添加自定义脚本 → '
                  '推荐音源」测试并导入（原内置源已全部改为推荐导入）',
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ),
            if (readyScripts.isEmpty && activeInfo != null && !activePending)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Text(
                  '「${activeInfo.name}」暂未就绪（初始化约 10-15 秒）；'
                  '其余就绪脚本在上方可临时选用',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ),
            // 曲库平台：榜单/搜索维度（App 免签曲库能力），与激活脚本
            // 解耦，可自由切换
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text('曲库平台（lx 模式生效）',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final item in platforms)
                    ChoiceChip(
                      label: Text(lxPlatformName(item)),
                      selected: isLx && settings.lxPlatform == item,
                      onSelected: (_) => sourceStore.switchPlatform(item),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text('取流脚本', style: Theme.of(context).textTheme.titleSmall),
            ),
            ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.extension, color: scheme.outline),
              ),
              title: const Text('管理取流脚本'),
              subtitle: Text(
                _lxTotal == 0
                    ? '无脚本：到「添加自定义脚本 → 推荐音源」测试并导入'
                    : '$_lxReady/$_lxTotal 个就绪 · 酷我/网易云整曲由脚本出链',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => OtherSourcesPage(
                      onSettingsChanged: widget.onSettingsChanged,
                    ),
                  ),
                );
                await _refreshLx();
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text('说明', style: Theme.of(context).textTheme.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                '其他音源 = 取流脚本（对齐 lx-music「音源即脚本」）：'
                '选定具体脚本则播放只用该脚本取流（不可用时自动回退'
                '其它就绪脚本）。脚本从「管理取流脚本 → 推荐音源」导入。'
                '曲库平台决定首页榜单与搜索来源，可自由切换，不随脚本'
                '收敛（出链自动跳过不支持当前平台的脚本）。'
                '「最近播放」与「我喜欢的音乐」为全局内容，不受音源影响；'
                '已缓存曲目不受影响。',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 音源行：左侧图标（选中态着色）/ 标题 / 状态 / 测速徽标 / 详情按钮
/// （有详情页的音源才显示 chevron）。
class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.speed,
    required this.onSelect,
    this.onDetail,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final SpeedResult? speed;
  final VoidCallback onSelect;
  final VoidCallback? onDetail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          color: selected ? scheme.onPrimaryContainer : scheme.outline,
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (selected) ...[
            const SizedBox(width: 6),
            Icon(Icons.check_circle, size: 16, color: scheme.primary),
          ],
        ],
      ),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (speed != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: speed!.ok
                    ? Colors.green.withValues(alpha: 0.12)
                    : scheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                speed!.ok ? '${speed!.ms}ms' : '异常',
                style: TextStyle(
                  fontSize: 11,
                  color: speed!.ok
                      ? Colors.green.shade700
                      : scheme.onErrorContainer,
                ),
              ),
            ),
          if (onDetail != null)
            IconButton(
              tooltip: '详情 / 编辑',
              icon: Icon(Icons.chevron_right, color: scheme.outline),
              onPressed: onDetail,
            ),        ],
      ),
      onTap: onSelect,
    );
  }
}

/// 测速按钮 + 结果行（详情页共用）。
class _SpeedTestTile extends StatelessWidget {
  const _SpeedTestTile({
    required this.running,
    required this.result,
    required this.onTap,
  });

  final bool running;
  final String? result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.speed),
      title: const Text('测速'),
      subtitle: result == null
          ? null
          : Text(result!, style: const TextStyle(fontSize: 12)),
      trailing: running
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.play_arrow),
      onTap: running ? null : onTap,
    );
  }
}

/// 汽水账号音源详情：行为说明 + 试听回落开关 + 测速。
class SodaAccountSourcePage extends StatefulWidget {
  const SodaAccountSourcePage({super.key, required this.onSettingsChanged});

  final VoidCallback onSettingsChanged;

  @override
  State<SodaAccountSourcePage> createState() => _SodaAccountSourcePageState();
}

class _SodaAccountSourcePageState extends State<SodaAccountSourcePage> {
  bool _testing = false;
  bool _signerTesting = false;
  String? _signerResult;
  AccountInfo? _account;

  @override
  void initState() {
    super.initState();
    _loadAccount();
  }

  /// 账号信息（VIP 状态展示）：先缓存后线上。
  Future<void> _loadAccount() async {
    if (!settings.hasCookie) return;
    final cached = await MineCache.load();
    if (cached?.account != null && mounted) {
      setState(() => _account = cached!.account);
    }
    try {
      final account = await Api.account();
      if (mounted) setState(() => _account = account);
    } catch (_) {}
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    final stopwatch = Stopwatch()..start();
    try {
      final account = await Api.account();
      final ms = stopwatch.elapsedMilliseconds;
      if (mounted) setState(() => _account = account);
      speedStore.update('default', SpeedResult(ms: ms, text: '可用', ok: true));
      if (mounted) {
        setState(() => _testing = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('账号接口可用（$ms ms）：${account.nickname}')),
          );
      }
    } catch (error) {
      speedStore.update(
        'default',
        SpeedResult(ms: stopwatch.elapsedMilliseconds, text: '失败', ok: false),
      );
      if (mounted) {
        setState(() => _testing = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('测速失败：$error')));
      }
    }
  }

  /// 音质限免链路诊断：直测内置签名服务（免费曲全档位依赖它）。
  Future<void> _testSigner() async {
    setState(() => _signerTesting = true);
    final result = await Api.signerPing(
      settings.signerUrl,
      settings.signerToken,
    );
    if (mounted) {
      setState(() {
        _signerTesting = false;
        _signerResult = '${result.result}（${result.ms} ms）';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('汽水账号')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Text('详情', style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
            '默认音源。用当前登录的汽水账号取流，内部经内置签名服务实现'
              '「音质限免」：免费曲目可取全景声/录音室/无损全档；VIP 专属'
              '曲目整曲按账号权益（无权益时为 60 秒试听，可开下方回落取'
              '免费整曲）。音质档位跟随「设置 → 音质」。',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
          const SizedBox(height: 12),
          if (settings.hasCookie && _account != null)
            ListTile(
              leading: Icon(
                _account!.vip ? Icons.workspace_premium : Icons.person_outline,
                color: _account!.vip ? Colors.amber.shade700 : scheme.outline,
              ),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      _account!.nickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_account!.vip) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade700,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'VIP',
                        style: TextStyle(fontSize: 11, color: Colors.white),
                      ),
                    ),
                  ],
                ],
              ),
              subtitle: Text(
                _account!.vip
                    ? 'VIP 会员：VIP 曲目整曲，音质按「设置 → 音质」'
                    : '非 VIP：VIP 曲目 60 秒试听（可开下方回落取免费整曲）',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          _SpeedTestTile(
            running: _testing,
            result: speedStore.of('default') == null
                ? '测试汽水接口往返延迟'
                : '${speedStore.of('default')!.text}'
                      '（${speedStore.of('default')!.ms} ms）',
            onTap: _test,
          ),
          ListTile(
            leading: const Icon(Icons.graphic_eq),
            title: const Text('音质限免 · 签名服务'),
            subtitle: Text(
              _signerResult ??
                  '免费曲全景声/录音室/无损依赖内置签名服务（异常时自动'
                  '回落标准音质）',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: _signerTesting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            onTap: _signerTesting ? null : _testSigner,
          ),
          if (!settings.hasCookie)
            ListTile(
              leading: Icon(Icons.info_outline, color: scheme.error),
              title: const Text('未登录'),
              subtitle: const Text(
                '登录后可用账号权益（在「我的」页登录）',
                style: TextStyle(fontSize: 12),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Text('编辑', style: Theme.of(context).textTheme.titleSmall),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.library_music),
            title: const Text('试听歌曲自动回落外部整曲'),
            subtitle: const Text(
              '汽水侧只有试听（VIP/会话限制）时，按标题+歌手经洛雪脚本'
              '匹配免费整曲；汽水整曲不受影响',
              style: TextStyle(fontSize: 12),
            ),
            value: settings.extEnabled,
            onChanged: (value) async {
              setState(() => settings.extEnabled = value);
              await settings.save();
              final cacheDir = await Settings.resolveCacheDir();
              await Api.configure(settings.toFfiConfig(cacheDir));
              widget.onSettingsChanged();
            },
          ),
        ],
      ),
    );
  }
}

