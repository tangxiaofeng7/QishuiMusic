/// 封面主色提取（零三方依赖）：给播放页沉浸式背景取色。
///
/// 输入是已下载到磁盘的封面文件（复用 cover.dart 的缓存），
/// `dart:ui` 解码成 24×24 缩略图后按 HSV 做饱和度加权直方图：
/// 高饱和像素才有投票权（灰底/白边不干扰），36 个色相桶取最优再求均值。
/// 全图近灰时回落「平均色」，保证任何封面都有可用结果。

library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui hide TextStyle;

import 'logging.dart';

class Palette {
  Palette._();

  static final Map<String, ui.Color?> _cache = {};

  /// 提取封面主色；失败/空文件返回 null（UI 回落主题色）。
  static Future<ui.Color?> dominant(String coverUrl, File? file) {
    final cached = _cache[coverUrl];
    if (cached != null || _cache.containsKey(coverUrl)) {
      return Future.value(_cache[coverUrl]);
    }
    return _extract(coverUrl, file);
  }

  static Future<ui.Color?> _extract(String url, File? file) async {
    ui.Color? result;
    try {
      if (file != null && file.existsSync() && file.lengthSync() > 0) {
        final data = await file.readAsBytes();
        final codec = await ui.instantiateImageCodec(
          data,
          targetWidth: 24,
          targetHeight: 24,
        );
        final frame = await codec.getNextFrame();
        final bytes = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        frame.image.dispose();
        if (bytes != null) {
          result = _fromRgba(bytes);
        }
      }
    } catch (error) {
      appLog('palette: 取色失败（回落主题色）: $error');
    }
    _cache[url] = result;
    return result;
  }

  /// RGBA 缩略图 → 主色。
  static ui.Color? _fromRgba(ByteData bytes) {
    final pixelCount = bytes.lengthInBytes ~/ 4;
    if (pixelCount == 0) return null;
    // 36 个色相桶 × 3 档明度：累计 (r,g,b,sat 权重)。
    final buckets = List.generate(
      36,
      (_) => List.generate(3, (_) => <double>[0, 0, 0, 0]),
      growable: false,
    );
    var grayR = 0.0, grayG = 0.0, grayB = 0.0, grayN = 0;
    for (var i = 0; i < pixelCount; i++) {
      final r = bytes.getUint8(i * 4) / 255;
      final g = bytes.getUint8(i * 4 + 1) / 255;
      final b = bytes.getUint8(i * 4 + 2) / 255;
      final max = math.max(r, math.max(g, b));
      final min = math.min(r, math.min(g, b));
      final value = max;
      final delta = max - min;
      final saturation = max <= 0 ? 0.0 : delta / max;
      if (saturation < 0.18) {
        grayR += r;
        grayG += g;
        grayB += b;
        grayN++;
        continue;
      }
      var hue = 0.0;
      if (delta > 0) {
        if (max == r) {
          hue = 60 * (((g - b) / delta) % 6);
        } else if (max == g) {
          hue = 60 * ((b - r) / delta + 2);
        } else {
          hue = 60 * ((r - g) / delta + 4);
        }
        if (hue < 0) hue += 360;
      }
      // 中等明度权重最高（太暗/过曝的像素少投票）
      final valueWeight = 1.0 - (value - 0.62).abs().clamp(0.0, 0.6);
      final weight = saturation * saturation * valueWeight;
      final hueBucket = (hue ~/ 10).clamp(0, 35);
      final valueBucket = value < 0.45 ? 0 : (value < 0.8 ? 1 : 2);
      final bucket = buckets[hueBucket][valueBucket];
      bucket[0] += r * weight;
      bucket[1] += g * weight;
      bucket[2] += b * weight;
      bucket[3] += weight;
    }
    double? bestScore;
    List<double>? bestBucket;
    for (final row in buckets) {
      for (final bucket in row) {
        if (bucket[3] <= 0) continue;
        if (bestBucket == null || bucket[3] > bestScore!) {
          bestScore = bucket[3];
          bestBucket = bucket;
        }
      }
    }
    if (bestBucket != null && bestBucket[3] > 0) {
      return ui.Color.fromRGBO(
        (bestBucket[0] / bestBucket[3] * 255).round().clamp(0, 255),
        (bestBucket[1] / bestBucket[3] * 255).round().clamp(0, 255),
        (bestBucket[2] / bestBucket[3] * 255).round().clamp(0, 255),
        1,
      );
    }
    if (grayN > 0) {
      // 全图近灰：平均色
      return ui.Color.fromRGBO(
        (grayR / grayN * 255).round().clamp(0, 255),
        (grayG / grayN * 255).round().clamp(0, 255),
        (grayB / grayN * 255).round().clamp(0, 255),
        1,
      );
    }
    return null;
  }
}

/// Color 便捷扩展：播放页沉浸式背景派生色。
extension PaletteColorUtils on ui.Color {
  /// 压暗（amount 0~1）：沉浸背景顶部。
  ui.Color darken(double amount) => ui.Color.fromARGB(
        (a * 255).round().clamp(0, 255),
        (r * 255 * (1 - amount)).round().clamp(0, 255),
        (g * 255 * (1 - amount)).round().clamp(0, 255),
        (b * 255 * (1 - amount)).round().clamp(0, 255),
      );

  /// 提亮（amount 0~1）：暗背景上的文字可用主色提亮一档。
  ui.Color lighten(double amount) => ui.Color.fromARGB(
        (a * 255).round().clamp(0, 255),
        (r * 255 + (255 - r * 255) * amount).round().clamp(0, 255),
        (g * 255 + (255 - g * 255) * amount).round().clamp(0, 255),
        (b * 255 + (255 - b * 255) * amount).round().clamp(0, 255),
      );
}
