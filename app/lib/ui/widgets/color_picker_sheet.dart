import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 通用 HSV 选色器底单（设置 → 个性化外观 → 播放页壁纸自定义颜色）：
/// 饱和度/明度面板 + 色相条 + 十六进制输入，自绘实现零第三方依赖。
///
/// [previewBuilder] 接收当前选中色渲染用途预览（壁纸场景传渐变条），
/// 不传则显示纯色圆点。
Future<void> showColorPickerSheet(
  BuildContext context, {
  required Color initial,
  required ValueChanged<Color> onConfirm,
  Widget Function(Color selected)? previewBuilder,
  String title = '选择颜色',
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => _ColorPickerSheet(
      initial: initial,
      onConfirm: onConfirm,
      previewBuilder: previewBuilder,
      title: title,
    ),
  );
}

class _ColorPickerSheet extends StatefulWidget {
  const _ColorPickerSheet({
    required this.initial,
    required this.onConfirm,
    required this.previewBuilder,
    required this.title,
  });

  final Color initial;
  final ValueChanged<Color> onConfirm;
  final Widget Function(Color selected)? previewBuilder;
  final String title;

  @override
  State<_ColorPickerSheet> createState() => _ColorPickerSheetState();
}

class _ColorPickerSheetState extends State<_ColorPickerSheet> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final TextEditingController _hexController;
  final _hexFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _hexController = TextEditingController(text: _hexText(_hsv.toColor()));
    // 焦点变化：失焦时把面板当前色回填输入框（编辑中不打扰）
    _hexFocus.addListener(() {
      if (!_hexFocus.hasFocus) {
        _hexController.text = _hexText(_hsv.toColor());
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _hexController.dispose();
    _hexFocus.dispose();
    super.dispose();
  }

  String _hexText(Color color) =>
      (color.toARGB32() & 0xFFFFFF)
          .toRadixString(16)
          .toUpperCase()
          .padLeft(6, '0');

  void _updateHsv(HSVColor value) {
    setState(() {
      _hsv = value;
      if (!_hexFocus.hasFocus) _hexController.text = _hexText(value.toColor());
    });
  }

  /// 十六进制输入 → HSV（# 可选、忽略空白；非法片段静默忽略）。
  void _applyHex(String input) {
    final hex = input.trim().replaceFirst('#', '');
    if (hex.length != 6) return;
    final value = int.tryParse('FF$hex', radix: 16);
    if (value == null) return;
    _updateHsv(HSVColor.fromColor(Color(value)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _hsv.toColor();
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(widget.title,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (widget.previewBuilder != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: widget.previewBuilder!(selected),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: selected,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('#${_hexText(selected)}',
                        style: const TextStyle(
                            fontSize: 15,
                            fontFeatures: [FontFeature.tabularFigures()])),
                  ],
                ),
              ),
            _svArea(),
            const SizedBox(height: 16),
            _hueBar(),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('#',
                    style: TextStyle(
                        fontSize: 15, color: scheme.outline)),
                const SizedBox(width: 6),
                SizedBox(
                  width: 118,
                  child: TextField(
                    controller: _hexController,
                    focusNode: _hexFocus,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9a-fA-F#]')),
                    ],
                    maxLength: 7,
                    decoration: const InputDecoration(
                      isDense: true,
                      counterText: '',
                      hintText: 'RRGGBB',
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(letterSpacing: 1.2),
                    onSubmitted: _applyHex,
                    onChanged: _applyHex,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    widget.onConfirm(selected);
                    Navigator.of(context).pop();
                  },
                  child: const Text('确定'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 饱和度 / 明度面板：横向白 → 纯色相，纵向透明 → 黑；
  /// 按下与拖动均取点。
  Widget _svArea() {
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, 180);
      return GestureDetector(
        onPanDown: (details) => _pickSv(details.localPosition, size),
        onPanUpdate: (details) => _pickSv(details.localPosition, size),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: CustomPaint(
            size: size,
            painter: _SvPainter(_hsv),
          ),
        ),
      );
    });
  }

  void _pickSv(Offset position, Size size) {
    final saturation = (position.dx / size.width).clamp(0.0, 1.0);
    final value = 1 - (position.dy / size.height).clamp(0.0, 1.0);
    _updateHsv(_hsv.withSaturation(saturation).withValue(value));
  }

  /// 色相条（0° ~ 360° 彩虹渐变）。
  Widget _hueBar() {
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, 26);
      return GestureDetector(
        onPanDown: (details) => _pickHue(details.localPosition, size),
        onPanUpdate: (details) => _pickHue(details.localPosition, size),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: CustomPaint(size: size, painter: _HuePainter(_hsv.hue)),
        ),
      );
    });
  }

  void _pickHue(Offset position, Size size) {
    final hue = (position.dx / size.width).clamp(0.0, 1.0) * 360;
    _updateHsv(_hsv.withHue(hue));
  }
}

/// SV 面板：底横向白 → 纯色相，叠纵向透明 → 黑；白圈为当前取值点。
class _SvPainter extends CustomPainter {
  const _SvPainter(this.hsv);

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, hsv.toColor()],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );

    final center = Offset(
      hsv.saturation * size.width,
      (1 - hsv.value) * size.height,
    );
    canvas.drawCircle(center, 11, Paint()..color = hsv.toColor());
    canvas.drawCircle(
      center,
      11,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_SvPainter oldDelegate) =>
      // 比较全 HSV 而非合成 RGB：纯白/纯黑下色相变化不改变颜色，
      // 但面板底色与取值点位置需要重绘
      oldDelegate.hsv.hue != hsv.hue ||
      oldDelegate.hsv.saturation != hsv.saturation ||
      oldDelegate.hsv.value != hsv.value;
}

/// 色相条：彩虹渐变 + 竖向取值指示。
class _HuePainter extends CustomPainter {
  const _HuePainter(this.hue);

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ).createShader(rect),
    );

    final dx = hue / 360 * size.width;
    final handle = Rect.fromCenter(
      center: Offset(dx, size.height / 2),
      width: 6,
      height: size.height + 6,
    );
    final rrect = RRect.fromRectAndRadius(
        handle, const Radius.circular(3));
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawRRect(rrect.inflate(1.5), Paint()..color = Colors.black26);
  }

  @override
  bool shouldRepaint(_HuePainter oldDelegate) =>
      (oldDelegate.hue - hue).abs() > 0.25;
}
