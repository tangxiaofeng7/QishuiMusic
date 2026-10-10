import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/logging.dart';
import '../../core/net.dart';
import '../../core/store.dart' as store;

/// 封面图：磁盘缓存 + 渐显 + 呼吸占位。
///
/// 缓存落在 `<cacheDir>/covers/<fnv64(url)>.img`（「已缓存曲目」清空时
/// 会顺带清这个目录）。列表滚动重复出现的封面只读本地文件，不再重复
/// 下载；下载失败做内存级负缓存，坏链不反复请求。
class CoverImage extends StatefulWidget {
  const CoverImage({super.key, required this.url, this.size = 48});

  final String url;
  final double size;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  File? _file;
  String _url = '';

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _resolve();
  }

  Future<void> _resolve() async {
    final url = widget.url.trim();
    _url = url;
    final file = await resolveCoverFile(url);
    if (!mounted || _url != url) return;
    setState(() => _file = file);
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    if (file != null && file.existsSync()) {
      // 列表/卡片小图按「显示尺寸 × DPR」缩略解码：封面原图 375~512px，
      // 48px 的行内图整图解码既是 CPU 大头也是内存大头（滚动掉帧的
      // 主要来源）；大图（播放页封面 ≥320）保持原尺寸。cacheWidth 超过
      // 原图尺寸时 Flutter 按原图解码，不会放大失真。
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.5;
      final int? cacheWidth =
          widget.size <= 300 ? (widget.size * dpr).round() : null;
      return Image.file(
        file,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(context),
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return const SizedBox.shrink();
        },
      );
    }
    return _placeholder(context);
  }

  /// 呼吸占位：加载中轻微脉动，空链/失败为静态灰底音符。
  Widget _placeholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pending = _url.isNotEmpty && !coverFailed(_url);
    final box = Container(
      width: widget.size,
      height: widget.size,
      color: scheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        size: widget.size * 0.5,
        color: scheme.outline,
      ),
    );
    if (!pending) return box;
    return _Pulse(child: box);
  }
}

// ---------------------------------------------------------------------------
// 封面缓存（模块级）：CoverImage 与取色（palette）共用同一份缓存
// ---------------------------------------------------------------------------

/// url → 本地文件（内存一级缓存，跨实例共享）。
final Map<String, File> _coverMem = {};

/// 下载失败的 url（负缓存，进程内不再重试）。
final Set<String> _coverFailed = {};

/// url → 进行中的下载（并发去重：同图多行只下一次）。
final Map<String, Future<File?>> _coverInFlight = {};

/// 该 url 是否已知下载失败（占位图静态化用）。
bool coverFailed(String url) => _coverFailed.contains(url);

/// 解析 url 的本地缓存文件：已缓存立即返回，在途下载等结果，
/// 未缓存则触发下载；失败返回 null。
Future<File?> resolveCoverFile(String url) async {
  url = url.trim();
  if (url.isEmpty || Uri.tryParse(url)?.hasScheme != true) return null;
  final cached = _coverMem[url];
  if (cached != null && cached.existsSync()) return cached;
  if (_coverFailed.contains(url)) return null;
  final file = await (_coverInFlight[url] ??= downloadCover(url));
  _coverInFlight.remove(url);
  if (file == null) {
    _coverFailed.add(url);
  } else {
    _coverMem[url] = file;
  }
  return file;
}

Future<File?> downloadCover(String url) async {
  try {
    final base = await store.Settings.resolveCacheDir();
    final dir = Directory('$base/covers');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    var hash = 0xcbf29ce484222325;
    for (final code in url.codeUnits) {
      hash ^= code;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    final file = File('${dir.path}/${hash.toRadixString(16)}.img');
    if (file.existsSync() && file.lengthSync() > 0) return file;
    // 共享 client（连接复用）：滚动列表里的封面下载不再逐张开新连接。
    final client = sharedHttpClient;
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.userAgentHeader, 'SodaM/1.0');
    final response = await request.close();
    if (response.statusCode != 200) return null;
    final sink = file.openWrite();
    await response.pipe(sink);
    if (file.lengthSync() <= 0) {
      file.deleteSync();
      return null;
    }
    return file;
  } catch (error) {
    appLog('cover: 下载失败（忽略）: $error');
    return null;
  }
}

/// 呼吸动画占位（0.45 ↔ 1.0 透明度循环）。
class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0)
          .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: widget.child,
    );
  }
}
