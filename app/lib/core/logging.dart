/// 文件日志：远程调试（越狱机 SSH）没有 oslog，把关键里程碑与
/// 未捕获异常落到 sodam-debug.log，便于 ssh 直读。

library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'store.dart';

String? _logPath;
bool _enabled = true;

/// 内存环形缓冲（运行日志页用）：保留最近若干条原始行，
/// 读取不必重扫日志文件。
const int _ringCapacity = 1000;
final List<String> _ring = <String>[];

/// 当前缓冲快照（旧 → 新）。
List<String> logBufferSnapshot() => List<String>.unmodifiable(_ring);

Future<void> initLogging() async {
  _ring.clear();
  try {
    // iOS 上 path_provider 在 SPM 构建里不可靠，统一走 TMPDIR 推导
    final root = await appContainerRoot();
    _logPath = '$root/Documents/sodam-debug.log';
  } catch (error) {
    _logPath = '${Directory.systemTemp.path}/sodam-debug.log';
  }
  try {
    // 单次会话从新文件开始，避免无限增长
    final file = File(_logPath!);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '=== SodaM ${DateTime.now().toIso8601String()} ===\n',
      mode: FileMode.write,
    );
  } catch (_) {
    // 系统级 App（/var/jb/Applications）没有容器 Documents：落到 tmp
    _logPath = '${Directory.systemTemp.path}/sodam-debug.log';
    try {
      final file = File(_logPath!);
      file.writeAsStringSync(
        '=== SodaM ${DateTime.now().toIso8601String()} ===\n',
        mode: FileMode.write,
      );
    } catch (_) {
      _enabled = false;
    }
  }
}

void appLog(String message) {
  debugPrint(message);
  _ring.add(message);
  if (_ring.length > _ringCapacity) {
    _ring.removeRange(0, _ring.length - _ringCapacity);
  }
  if (!_enabled) return;
  final path = _logPath;
  if (path == null) return;
  try {
    File(path).writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // 日志失败不能影响业务
  }
}

void logError(String where, Object error, [StackTrace? stack]) {
  appLog('ERROR[$where] $error');
  if (stack != null) {
    final text = stack.toString();
    // 只落前 3 帧，够定位
    appLog('ERROR[$where] ${text.split('\n').take(4).join(' | ')}');
  }
}

/// 调试读取日志路径（设置页展示 / 远程提示用）。
String? get logFilePath => _logPath;
