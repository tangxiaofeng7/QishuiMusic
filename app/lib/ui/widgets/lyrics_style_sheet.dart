import 'package:flutter/material.dart';

import '../../main.dart';

/// 歌词样式 DIY 底单（播放页快捷动作与设置 → 个性化外观共用）：
/// 字号 / 行距 / 自定义配色 / 发光 / 3D 倾斜，改动即时生效并持久化。
Future<void> showLyricsStyleSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => const _LyricsStyleSheet(),
  );
}

/// 歌词颜色候选（底色 / 高亮色共用一套小色板）。
const List<int> lyricColorPalette = [
  0xFFFFFFFF,
  0xFFE0E0E0,
  0xFFB0BEC5,
  0xFF808A93,
  0xFF3AAFA9,
  0xFF3D7BE8,
  0xFF7C5CE0,
  0xFFE8547C,
  0xFFF0704A,
  0xFFE8B93B,
  0xFF57B86B,
  0xFFFF5252,
];

class _LyricsStyleSheet extends StatelessWidget {
  const _LyricsStyleSheet();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('歌词样式',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              Text('仅影响播放页歌词区，改动即时生效',
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
              const SizedBox(height: 12),
              _PreviewLine(),
              const SizedBox(height: 12),
              _slider(
                context: context,
                icon: Icons.format_size,
                label: '字号',
                value: appearance.lyricFontSize,
                min: 12,
                max: 32,
                display: appearance.lyricFontSize.round().toString(),
                onChanged: (value) =>
                    appearance.updateLyrics(fontSize: value),
              ),
              _slider(
                context: context,
                icon: Icons.format_line_spacing,
                label: '行距',
                value: appearance.lyricLineSpacing,
                min: 0.6,
                max: 2.0,
                display: '${appearance.lyricLineSpacing.toStringAsFixed(1)}x',
                onChanged: (value) =>
                    appearance.updateLyrics(lineSpacing: value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自定义配色'),
                subtitle: Text('关闭时跟随播放页封面取色',
                    style: TextStyle(fontSize: 12, color: scheme.outline)),
                value: appearance.lyricCustomColors,
                onChanged: (value) =>
                    appearance.updateLyrics(customColors: value),
              ),
              if (appearance.lyricCustomColors) ...[
                _colorRow(
                  context: context,
                  label: '未唱到',
                  selected: appearance.lyricBaseColor.toARGB32(),
                  onPicked: (color) =>
                      appearance.updateLyrics(baseColor: color),
                ),
                _colorRow(
                  context: context,
                  label: '高亮',
                  selected: appearance.lyricHighlightColor.toARGB32(),
                  onPicked: (color) =>
                      appearance.updateLyrics(highlightColor: color),
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('当前行发光'),
                value: appearance.lyricGlow,
                onChanged: (value) => appearance.updateLyrics(glow: value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('3D 倾斜'),
                subtitle: Text('当前行轻微透视，仿黑胶唱片机的视觉纵深',
                    style: TextStyle(fontSize: 12, color: scheme.outline)),
                value: appearance.lyricTilt,
                onChanged: (value) => appearance.updateLyrics(tilt: value),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('恢复默认'),
                  onPressed: appearance.resetLyrics,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _slider({
    required BuildContext context,
    required IconData icon,
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: scheme.outline),
        const SizedBox(width: 10),
        SizedBox(width: 36, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) * 10).round(),
            label: display,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(display,
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: 13, color: scheme.outline)),
        ),
      ],
    );
  }

  Widget _colorRow({
    required BuildContext context,
    required String label,
    required int selected,
    required ValueChanged<int> onPicked,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final color in lyricColorPalette)
                GestureDetector(
                  onTap: () => onPicked(color),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Color(color),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected == color
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white24,
                        width: selected == color ? 3 : 1,
                      ),
                    ),
                    child: selected == color
                        ? const Icon(Icons.check,
                            size: 16, color: Colors.black87)
                        : null,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 当前行效果预览：套用字号 / 配色 / 发光 / 3D 倾斜的静态扫色行。
class _PreviewLine extends StatelessWidget {
  static const _sweep = 0.65;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = appearance.lyricCustomColors
        ? appearance.lyricBaseColor
        : scheme.outline;
    final highlight = appearance.lyricCustomColors
        ? appearance.lyricHighlightColor
        : scheme.primary;
    final line = ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => LinearGradient(
        colors: [highlight, highlight, base, base],
        stops: const [0, _sweep, _sweep, 1],
      ).createShader(bounds),
      child: Text(
        '这是一行正在播放的歌词',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: appearance.lyricFontSize,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          shadows: appearance.lyricGlow
              ? [
                  Shadow(color: highlight, blurRadius: 16),
                  Shadow(
                      color: highlight.withValues(alpha: 0.55), blurRadius: 30),
                ]
              : null,
        ),
      ),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: appearance.lyricTilt
          ? Transform(
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.002)
                ..rotateX(-0.18),
              alignment: Alignment.center,
              child: line,
            )
          : line,
    );
  }
}
