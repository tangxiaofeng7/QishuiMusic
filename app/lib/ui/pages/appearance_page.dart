import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/appearance.dart';
import '../../main.dart';
import '../widgets/color_picker_sheet.dart';
import '../widgets/lyrics_style_sheet.dart';

/// 个性化外观（借鉴 Beans-Music 的 DIY 美化）：
/// 主题色板 / 播放页壁纸 / 进度条样式 / 歌词样式 / 快捷按钮排序。
class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key});

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  File? _wallpaperFile;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _resolveWallpaper();
  }

  Future<void> _resolveWallpaper() async {
    final file = appearance.wallpaperIsPhoto ? await wallpaperFile() : null;
    final exists = file != null && file.existsSync();
    if (!mounted) return;
    setState(() => _wallpaperFile = exists ? file : null);
  }

  Future<void> _pickPhoto() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final photo = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
      );
      if (photo == null) return;
      final file = await wallpaperFile();
      await file.writeAsBytes(await photo.readAsBytes());
      appearance.setWallpaper('photo');
      await _resolveWallpaper();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('选择壁纸失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('个性化外观')),
      body: ListenableBuilder(
        listenable: appearance,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            _card('主题色', [
              SwitchListTile(
                secondary: const Icon(Icons.auto_awesome),
                title: const Text('跟随封面取色'),
                subtitle: const Text('全局主题色随当前曲目封面变化（默认）'),
                value: appearance.accentFollowCover,
                onChanged: (value) =>
                    appearance.setAccent(followCover: value),
              ),
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 200),
                crossFadeState: appearance.accentFollowCover
                    ? CrossFadeState.showFirst
                    : CrossFadeState.showSecond,
                firstChild: const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text('关闭后使用下方自选主题色',
                      style: TextStyle(fontSize: 12)),
                ),
                secondChild: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Wrap(
                    spacing: 14,
                    runSpacing: 12,
                    children: [
                      for (final (color, name) in accentPresets)
                        _ColorSwatch(
                          color: color,
                          name: name,
                          selected:
                              appearance.accentColor.toARGB32() == color.toARGB32(),
                          onTap: () => appearance.setAccent(
                              followCover: false, color: color.toARGB32()),
                        ),
                    ],
                  ),
                ),
              ),
            ]),
            _card('播放页壁纸', [
              _wallpaperPreview(),
              ListTile(
                leading: const Icon(Icons.gradient),
                title: const Text('封面取色渐变'),
                subtitle: const Text('默认：随封面主色的沉浸式渐变'),
                trailing: appearance.wallpaper == 'auto'
                    ? const Icon(Icons.check_circle)
                    : null,
                onTap: () => appearance.setWallpaper('auto'),
              ),
              ListTile(
                leading: _customColorChip(),
                title: const Text('自定义颜色'),
                subtitle: Text(
                    '当前 #${_hexLabel(appearance.wallpaperColor.toARGB32())} · '
                    '任意取色生成沉浸式渐变'),
                trailing: appearance.wallpaperIsCustom
                    ? const Icon(Icons.check_circle)
                    : const Icon(Icons.chevron_right),
                onTap: () => showColorPickerSheet(
                      context,
                      initial: appearance.wallpaperColor,
                      previewBuilder: (color) => _gradientBox(
                          customWallpaperGradient(color.toARGB32())),
                      onConfirm: (color) =>
                          appearance.setWallpaperColor(color.toARGB32()),
                    ),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('从相册选择'),
                subtitle: Text(appearance.wallpaperIsPhoto
                    ? '已启用相册壁纸 · 点按可重选'
                    : '选一张自己的照片当播放页背景'),
                trailing: _picking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : appearance.wallpaperIsPhoto
                        ? const Icon(Icons.check_circle,
                            color: Color(0xFF57B86B))
                        : null,
                onTap: _pickPhoto,
              ),
              if (appearance.wallpaperIsPhoto)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      const Text('模糊度'),
                      Expanded(
                        child: Slider(
                          value: appearance.wallpaperBlur,
                          max: 30,
                          divisions: 30,
                          label: appearance.wallpaperBlur.round().toString(),
                          onChanged: appearance.setWallpaperBlur,
                        ),
                      ),
                      SizedBox(
                        width: 30,
                        child: Text('${appearance.wallpaperBlur.round()}',
                            textAlign: TextAlign.end),
                      ),
                    ],
                  ),
                ),
            ]),
            _card('进度条样式', [
              for (final style in ProgressBarStyle.values)
                ListTile(
                  title: Text(style.label),
                  leading: Icon(switch (style) {
                    ProgressBarStyle.classic => Icons.linear_scale,
                    ProgressBarStyle.streamer => Icons.auto_awesome,
                    ProgressBarStyle.glow => Icons.blur_on,
                    ProgressBarStyle.aurora => Icons.filter_tilt_shift,
                    ProgressBarStyle.wave => Icons.waves,
                  }),
                  trailing: appearance.progressBar == style
                      ? const Icon(Icons.check_circle)
                      : null,
                  onTap: () => appearance.setProgressBar(style),
                ),
            ]),
            _card('歌词样式', [
              ListTile(
                leading: const Icon(Icons.lyrics_outlined),
                title: const Text('歌词样式 DIY'),
                subtitle: Text(
                  '字号 ${appearance.lyricFontSize.round()} · 行距 '
                  '${appearance.lyricLineSpacing.toStringAsFixed(1)}x'
                  '${appearance.lyricCustomColors ? ' · 自定义配色' : ''}'
                  '${appearance.lyricGlow ? ' · 发光' : ''}'
                  '${appearance.lyricTilt ? ' · 3D 倾斜' : ''}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showLyricsStyleSheet(context),
              ),
            ]),
            _card('播放页快捷按钮', [
              const ListTile(
                leading: Icon(Icons.drag_indicator),
                title: Text('长按拖动排序'),
                subtitle: Text(
                    '播放页控制栏下方的快捷按钮行，长按任意按钮即可拖动换位，'
                    '顺序自动保存'),
              ),
              Padding(
                padding: EdgeInsets.zero,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('恢复默认排序'),
                    onPressed: appearance.resetPlayerActions,
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _card(String title, List<Widget> children) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(title, style: theme.textTheme.titleSmall),
          ),
          ...children,
        ],
      ),
    );
  }

  /// 当前壁纸预览条：按生效背景渲染（照片 / 自选色渐变 / 旧渐变 / 封面渐变兜底）。
  Widget _wallpaperPreview() {
    final preset = appearance.wallpaperPreset;
    final custom = appearance.wallpaperCustomColors;
    final file = _wallpaperFile;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 64,
          width: double.infinity,
          child: appearance.wallpaperIsPhoto && file != null
              ? Image.file(file,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _gradientBox())
              : _gradientBox(custom ?? preset?.colors),
        ),
      ),
    );
  }

  /// 「自定义颜色」行首圆片：直接展示自选色派生出的壁纸渐变。
  Widget _customColorChip() {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: customWallpaperGradient(appearance.wallpaperColor.toARGB32()),
        ),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
    );
  }

  String _hexLabel(int argb) => (argb & 0xFFFFFF)
      .toRadixString(16)
      .toUpperCase()
      .padLeft(6, '0');

  Widget _gradientBox([List<Color>? colors]) {
    final scheme = Theme.of(context).colorScheme;
    final list = colors ?? [scheme.primary.darkenValue(0.2), scheme.primary];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: list,
        ),
      ),
      child: Center(
        child: Icon(Icons.music_note, color: Colors.white.withValues(alpha: 0.7)),
      ),
    );
  }
}

extension on Color {
  /// 简单压暗（外观页预览条用，避免引 palette 的扩展冲突）。
  Color darkenValue(double amount) => Color.fromARGB(
        (a * 255).round().clamp(0, 255),
        (r * 255 * (1 - amount)).round().clamp(0, 255),
        (g * 255 * (1 - amount)).round().clamp(0, 255),
        (b * 255 * (1 - amount)).round().clamp(0, 255),
      );
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 3 : 1,
              ),
            ),
            child: selected
                ? const Icon(Icons.check, size: 22, color: Colors.white)
                : null,
          ),
          const SizedBox(height: 4),
          Text(name, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}
