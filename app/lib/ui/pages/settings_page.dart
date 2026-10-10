import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kProfileMode, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../brand.dart';
import '../../core/api.dart';
import '../../core/cache_index.dart';
import '../../core/changelog.dart';
import '../../core/lx_catalog.dart';
import '../../core/lx_runtime.dart';
import '../../core/platform.dart';
import '../../core/store.dart';
import '../../core/updater.dart';
import '../../main.dart';
import '../nav.dart';
import 'appearance_page.dart';
import 'cached_tracks_page.dart';
import 'legal_page.dart';
import 'licenses_page.dart';
import 'logs_page.dart';
import 'sources_page.dart';

/// 设置：卡片式分组（对齐 LCSign 布局）——
/// 播放 / 外观 / 存储 / 软件（日志·协议·许可证·更新）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.onSettingsChanged});

  final VoidCallback onSettingsChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int? _cacheBytes;
  int? _cacheFiles;
  bool _checking = false;
  Map<String, String>? _device;

  @override
  void initState() {
    super.initState();
    _loadCache();
    _loadDeviceInfo();
    // IndexedStack 保活切 Tab 不重建：监听 Tab 切换，回到设置页即刷新
    // 缓存统计（播放新歌会持续落缓存，否则展示的是旧数字）。
    homeTabIndex.addListener(_onTabSwitched);
  }

  @override
  void dispose() {
    homeTabIndex.removeListener(_onTabSwitched);
    super.dispose();
  }

  void _onTabSwitched() {
    if (homeTabIndex.value == kSettingsTabIndex) _loadCache();
  }

  Future<void> _loadCache() async {
    try {
      final entries = await CacheIndex.list();
      if (mounted) {
        setState(() {
          _cacheFiles = entries.length;
          _cacheBytes = entries.fold<int>(0, (sum, entry) => sum + entry.bytes);
        });
      }
    } catch (_) {
      // 忽略
    }
  }

  String _sizeLabel(int bytes) {
    if (bytes < 1024 * 1024) return '${bytes ~/ 1024} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Future<void> _loadDeviceInfo() async {
    final info = await deviceInfo();
    if (mounted && info != null) setState(() => _device = info);
  }

  static String get _buildMode =>
      kReleaseMode ? 'Release' : (kProfileMode ? 'Profile' : 'Debug');

  /// 摘要副标题：iOS 18.2 · iPhone · Release（未取到原生信息时降级提示）。
  String get _envSummary {
    final info = _device;
    if (info == null) return '系统 / 设备 / 构建信息';
    final os = '${info['os'] ?? ''} ${info['osVersion'] ?? ''}'.trim();
    return [
      if (os.isNotEmpty) os,
      if ((info['model'] ?? '').isNotEmpty) info['model'],
      _buildMode,
    ].join(' · ');
  }

  /// 运行环境详情（借鉴 Beans-Music 崩溃日志的环境字段：
  /// 版本 / 设备 / 系统，外加构建模式与模拟器标识）。
  void _showEnvSheet() {
    final info = _device;
    final os =
        '${info?['os'] ?? Platform.operatingSystem} ${info?['osVersion'] ?? Platform.operatingSystemVersion}'
            .trim();
    final model = info?['model'] ?? '';
    final machine = info?['machine'] ?? '';
    final simulator = info?['simulator'] == 'true';
    // iPhone（iPhone17,1）；只取到其一（或都没取到）时降级显示
    final deviceLabel = switch ((model, machine)) {
      ('', '') => '',
      (_, '') => model,
      ('', _) => machine,
      _ => '$model（$machine）',
    };
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '运行环境',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              _envRow('应用版本', 'v$kAppVersion'),
              _envRow('系统', os),
              if (deviceLabel.isNotEmpty) _envRow('设备', deviceLabel),
              _envRow('环境', simulator ? '模拟器' : '真机'),
              _envRow('构建模式', _buildMode),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('复制环境信息'),
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(
                        text: [
                          '$kAppName v$kAppVersion',
                          '系统：$os',
                          if (deviceLabel.isNotEmpty) '设备：$deviceLabel',
                          '环境：${simulator ? '模拟器' : '真机'}',
                          '模式：$_buildMode',
                        ].join('\n'),
                      ),
                    );
                    ScaffoldMessenger.of(sheetContext)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        const SnackBar(content: Text('环境信息已复制，反馈问题时直接粘贴')),
                      );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _envRow(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }

  /// 交流群：优先拉起 Telegram，系统拒绝时复制链接兜底。
  Future<void> _openCommunity() async {
    final ok = await openUrl(kCommunityUrl);
    if (!mounted || ok) return;
    await Clipboard.setData(const ClipboardData(text: kCommunityUrl));
    _snack('未能拉起 Telegram，链接已复制，可粘贴到浏览器打开');
  }

  String get _sourceName => settings.sourceName;

  Future<void> _pickQuality() async {
    // LX 模式档位随就绪脚本动态变化：面板打开前刷新一次脚本状态
    if (settings.sourceMode == 'lx') {
      await LxRuntime.instance.ensureStarted();
      await LxRuntime.instance.refreshStatus();
    }
    if (!mounted) return;
    // 档位选项按音源动态出：汽水 = 账号五档；其他音源 = 当前平台
    // 就绪脚本声明 qualitys 的并集（不写死，随脚本/平台变化）。
    final isLx = settings.sourceMode == 'lx';
    final options = <(String, String)>[
      if (isLx)
        for (final quality in LxRuntime.instance.availableQualities(
          settings.lxPlatform,
        ))
          (quality, lxQualityLabels[quality] ?? quality)
      else
        for (final entry in qualityOptions.entries) (entry.key, entry.value),
    ];
    final selectedKey = isLx ? settings.lxQuality : settings.quality;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '播放音质',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final (key, label) in options)
              ListTile(
                title: Text(label),
                trailing: selectedKey == key ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, key),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  isLx
                      ? '选项 = ${lxPlatformName(settings.lxPlatform)}平台就绪脚本'
                            '实际支持的音质；所选档位不可用时自动逐级回落'
                      : '自动 = 最优档位；全景声/录音室/无损依赖当前音源与曲目支持',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || picked == selectedKey) return;
    setState(() {
      if (isLx) {
        settings.lxQuality = picked; // Dart 侧解析链偏好，不进 FFI 配置
      } else {
        settings.quality = picked;
      }
    });
    await settings.save();
    if (!isLx) {
      final cacheDir = await Settings.resolveCacheDir();
      await Api.configure(settings.toFfiConfig(cacheDir));
    }
    widget.onSettingsChanged();
    // 与播放页音质底单同行为：正在播的歌保持进度重载到新档位
    player.reloadCurrent();
  }

  Future<void> _pickTheme() async {
    final themes = const {'system': '跟随系统', 'dark': '深色', 'light': '浅色'};
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('主题', style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final entry in themes.entries)
              ListTile(
                title: Text(entry.value),
                trailing: settings.themeMode == entry.key
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, entry.key),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() => settings.themeMode = picked);
    await settings.save();
    widget.onSettingsChanged();
  }

  // ---- 在线升级 ----

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    final result = await Updater.check();
    if (!mounted) return;
    setState(() => _checking = false);
    switch (result.status) {
      case UpdateCheck.available:
        _showUpdateSheet(result.release!);
      case UpdateCheck.latest:
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('已是最新版本（${result.release!.version}）')),
          );
      case UpdateCheck.error:
        final error = result.error ?? '';
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                error.contains('404')
                    ? '暂无可用更新（仓库还没有发布版本）'
                    : '检查更新失败：$error（GitHub 需可直连）',
              ),
            ),
          );
    }
  }

  void _showUpdateSheet(ReleaseInfo release) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('发现新版本', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'v${release.version}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '当前版本 $kAppVersion',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    release.notes.trim().isEmpty ? '（无更新说明）' : release.notes,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(height: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('立即更新'),
                  onPressed: () async {
                    final message = await Updater.startInstall(release);
                    if (!context.mounted) return;
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(content: Text(message)));
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- 个性化配置备份（借鉴 Beans-Music 的一键备份/恢复）----

  Map<String, dynamic> _backupMap() => {
    'format': 'qishui-appearance',
    'version': 1,
    'exportedAt': DateTime.now().toIso8601String(),
    'themeMode': settings.themeMode,
    'lyricTranslation': settings.lyricTranslation,
    'appearance': appearance.toBackupMap(),
  };

  Future<void> _exportByShare() async {
    try {
      final json = const JsonEncoder.withIndent('  ').convert(_backupMap());
      final file = File('${Directory.systemTemp.path}/qishui-appearance.json');
      await file.writeAsString(json);
      await Share.shareXFiles([XFile(file.path)], text: '汽水播放器 · 个性化配置备份');
    } catch (error) {
      if (!mounted) return;
      _snack('导出失败：$error');
    }
  }

  Future<void> _exportByClipboard() async {
    final json = const JsonEncoder.withIndent('  ').convert(_backupMap());
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    _snack('配置 JSON 已复制，粘贴到备忘录等任意位置即可保存');
  }

  Future<void> _importFromPaste() async {
    final controller = TextEditingController();
    // 尝试用剪贴板内容预填（刚导出到剪贴板的情况一步恢复）
    final clipped = await Clipboard.getData('text/plain');
    if (clipped?.text?.contains('"qishui-appearance"') == true) {
      controller.text = clipped!.text!;
    }
    if (!mounted) {
      controller.dispose();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入配置'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            maxLines: 8,
            minLines: 4,
            decoration: const InputDecoration(
              hintText: '粘贴之前导出的配置 JSON',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final map = jsonDecode(controller.text.trim());
      if (map is! Map<String, dynamic> || map['appearance'] is! Map) {
        throw '不是有效的汽水播放器配置';
      }
      appearance.applyBackupMap(
        (map['appearance'] as Map).cast<String, dynamic>(),
      );
      final themeMode = map['themeMode'];
      if (themeMode is String) settings.themeMode = themeMode;
      final translation = map['lyricTranslation'];
      if (translation is bool) settings.lyricTranslation = translation;
      await settings.save();
      if (!mounted) return;
      setState(() {});
      widget.onSettingsChanged();
      _snack('配置已恢复');
    } catch (error) {
      _snack('导入失败：$error');
    } finally {
      controller.dispose();
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 音质副标题随音源出档位名：汽水六档 / LX 脚本档位（128k/320k/flac…）
    final qualityLabel = settings.sourceMode == 'lx'
        ? (lxQualityLabels[settings.lxQuality] ?? '自动')
        : (qualityOptions[settings.quality] ?? settings.quality);
    final themeLabel = switch (settings.themeMode) {
      'dark' => '深色',
      'light' => '浅色',
      _ => '跟随系统',
    };
    final hasNew = Updater.pendingUpdate != null;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          _SettingsCard(
            children: [
              ListTile(
                leading: const Icon(Icons.graphic_eq),
                title: const Text('播放音源'),
                subtitle: Text(_sourceName),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SourcesPage(
                        onSettingsChanged: widget.onSettingsChanged,
                      ),
                    ),
                  );
                  if (mounted) setState(() {});
                },
              ),
              _divider,
              ListTile(
                leading: const Icon(Icons.high_quality_outlined),
                title: const Text('音质'),
                subtitle: Text(qualityLabel),
                trailing: const Icon(Icons.chevron_right),
                onTap: _pickQuality,
              ),
            ],
          ),
          _SettingsCard(
            children: [
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('主题'),
                subtitle: Text(themeLabel),
                trailing: const Icon(Icons.chevron_right),
                onTap: _pickTheme,
              ),
              _divider,
              ListTile(
                leading: const Icon(Icons.auto_awesome_outlined),
                title: const Text('个性化外观'),
                subtitle: const Text('主题色板 / 壁纸 / 进度条 / 歌词样式'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AppearancePage(),
                  ),
                ),
              ),
            ],
          ),
          _SettingsCard(
            children: [
              ListTile(
                leading: const Icon(Icons.cloud_upload_outlined),
                title: const Text('备份与恢复'),
                subtitle: const Text('DIY 配置导出为 JSON，可分享或粘贴恢复'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  builder: (sheetContext) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '备份与恢复',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        ListTile(
                          leading: const Icon(Icons.ios_share),
                          title: const Text('导出 · 分享文件'),
                          subtitle: const Text('生成 JSON 文件，可存到「文件」或发送'),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            _exportByShare();
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.content_copy),
                          title: const Text('导出 · 复制 JSON'),
                          subtitle: const Text('复制到剪贴板，自行粘贴保存'),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            _exportByClipboard();
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.content_paste),
                          title: const Text('导入 · 粘贴恢复'),
                          subtitle: const Text('粘贴之前导出的配置 JSON'),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            _importFromPaste();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          _SettingsCard(
            children: [
              ListTile(
                leading: const Icon(Icons.download_done),
                title: const Text('已缓存曲目'),
                subtitle: _cacheBytes == null
                    ? null
                    : Text(
                        '$_cacheFiles 首 · ${_sizeLabel(_cacheBytes!)} · 点击播放',
                      ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CachedTracksPage(),
                    ),
                  );
                  // 返回时刷新统计（可能已清空/删除）
                  _loadCache();
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          _SettingsCard(
            children: [
              ListTile(
                leading: const Icon(Icons.memory_outlined),
                title: const Text('运行环境'),
                subtitle: Text(_envSummary),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showEnvSheet,
              ),
              _divider,
              ListTile(
                leading: const Icon(Icons.terminal_outlined),
                title: const Text('运行日志'),
                subtitle: const Text('查看实时运行记录'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LogsPage()),
                ),
              ),
              _divider,
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('服务协议'),
                subtitle: const Text('使用本应用前请阅读'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LegalPage()),
                ),
              ),
              _divider,
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('开源许可证'),
                subtitle: const Text('第三方组件及其许可证'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LicensesPage()),
                ),
              ),
              _divider,
              ListTile(
                leading: const Icon(Icons.article_outlined),
                title: const Text('更新日志'),
                subtitle: const Text('各版本新增与变更'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showChangelogList(context),
              ),
              _divider,
              ListTile(
                leading: const Icon(Icons.system_update_alt),
                title: const Text('检查更新'),
                subtitle: Text(
                  hasNew
                      ? '新版本 v${Updater.pendingUpdate!.version} 可用'
                      : '当前版本 $kAppVersion',
                ),
                trailing: _checking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : hasNew
                    ? Badge(
                        label: const Text('新'),
                        child: const Icon(Icons.chevron_right),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: _checkUpdate,
              ),
              _divider,
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: const Text('交流群'),
                subtitle: const Text('加入 Telegram 交流群'),
                trailing: const Icon(Icons.open_in_new),
                onTap: _openCommunity,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '$kAppName $kAppVersion · © 2026 汽水播放器',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  static const _divider = Divider(height: 1, indent: 16, endIndent: 16);
}

/// 分组卡片（对齐 LCSign 的圆角分组列表样式）。
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}
