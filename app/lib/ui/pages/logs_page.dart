import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/logging.dart';
import '../../core/platform.dart';

/// 运行日志：本会话 sodam-debug.log 实时查看（最新在上），
/// 支持复制 / 清空 / 系统分享导出。
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  List<String> _lines = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _reload();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _reload());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    List<String> lines;
    final path = logFilePath;
    try {
      if (path != null && File(path).existsSync()) {
        final raw = File(path).readAsStringSync();
        lines = raw.split('\n');
      } else {
        lines = logBufferSnapshot();
      }
    } catch (_) {
      lines = logBufferSnapshot();
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    if (!mounted) return;
    setState(() => _lines = lines);
  }

  /// `2026-10-09T07:21:33.123456 消息` → `07:21:33 消息`。
  String _pretty(String line) {
    final match =
        RegExp(r'^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})(?:\.\d+)?\s?(.*)$')
            .firstMatch(line);
    if (match == null) return line;
    return '${match.group(2)}  ${match.group(3)}';
  }

  Color? _lineColor(String line, BuildContext context) {
    if (line.contains('ERROR[') || line.contains('=== ')) {
      return Theme.of(context).colorScheme.error;
    }
    if (line.contains('WARN') || line.contains('失败') || line.contains('超时')) {
      return Colors.amber.shade700;
    }
    return null;
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(
      ClipboardData(text: _lines.map(_pretty).join('\n')),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('已复制全部日志'),
        duration: Duration(seconds: 1),
      ));
  }

  Future<void> _export() async {
    final path = logFilePath;
    if (path == null || !File(path).existsSync()) {
      _snack('日志文件不可用');
      return;
    }
    // 快照到 tmp 再分享（避免分享面板读文件时被清空操作截断）
    final stamp = DateTime.now().toIso8601String().split('.').first;
    final snapshot = '${Directory.systemTemp.path}/sodam-debug-$stamp.log';
    File(snapshot).writeAsStringSync(File(path).readAsStringSync());
    final ok = await shareFile(snapshot, mimeType: 'text/plain');
    if (!mounted) return;
    _snack(ok ? '已调出分享面板' : '分享不可用，日志在 $snapshot');
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('清空当前会话的运行日志？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final path = logFilePath;
    if (path != null) {
      try {
        File(path).writeAsStringSync(
          '=== cleared ${DateTime.now().toIso8601String()} ===\n',
          mode: FileMode.write,
        );
      } catch (_) {}
    }
    _reload();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final reversed = _lines.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: _copyAll,
          ),
          IconButton(
            tooltip: '导出日志',
            icon: const Icon(Icons.ios_share),
            onPressed: _export,
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: reversed.isEmpty
                ? Center(
                    child: Text('暂无日志',
                        style: Theme.of(context).textTheme.bodyMedium),
                  )
                : Scrollbar(
                    child: ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      itemCount: reversed.length,
                      itemBuilder: (context, index) => SelectableText(
                        _pretty(reversed[index]),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontFamilyFallback: const [
                            'Menlo',
                            'Courier New',
                          ],
                          fontSize: 12,
                          height: 1.45,
                          color: _lineColor(reversed[index], context),
                        ),
                      ),
                    ),
                  ),
          ),
          Container(
            width: double.infinity,
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 8,
              bottom: MediaQuery.paddingOf(context).bottom + 8,
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            child: Text(
              '${_lines.length} 行 · 每 2 秒自动刷新',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
