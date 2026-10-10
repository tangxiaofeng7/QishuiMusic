/// sodam_ffi（Rust）的 Dart FFI 绑定。
///
/// 原生侧是三个 C 符号（见 mobile/rust/sodam-ffi/src/lib.rs）：
/// * `sodam_init(config_json)` —— 配置/重建会话
/// * `sodam_request(method, params_json)` —— 业务调用（同步阻塞）
/// * `sodam_free(ptr)` —— 释放返回字符串
///
/// iOS 上 Rust 静态库链接进 Runner 主二进制（符号经 `DynamicLibrary.process()` 查找）；
/// Android 上打包为 jniLibs 里的 `libsodam_ffi.so`。

library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _InitC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _InitDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _RequestC = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _RequestDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _SignerPollC = Pointer<Utf8> Function();
typedef _SignerPollDart = Pointer<Utf8> Function();
typedef _SignerRespondC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _SignerRespondDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _SecondVerifyC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _SecondVerifyDart = Pointer<Utf8> Function(Pointer<Utf8>);

DynamicLibrary _open() {  if (Platform.isIOS) {
    // 首选：独立 Rust 动态框架（scripts/package-ipa.sh 注入 Frameworks/）
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final framework = '$appDir/Frameworks/sodam_ffi.framework/sodam_ffi';
    if (File(framework).existsSync()) {
      return DynamicLibrary.open(framework);
    }
    // 兜底：静态链入主程序/依赖镜像的符号
    return DynamicLibrary.process();
  }
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libsodam_ffi.so');
  }
  // 桌面调试（Windows/macOS/Linux）：cargo build --release 产物。
  // 相对路径同时兼容 app/ 与仓库根两个工作目录。
  if (Platform.isWindows) {
    const names = [
      'rust/sodam-ffi/target/release/sodam_ffi.dll',
      '../rust/sodam-ffi/target/release/sodam_ffi.dll',
    ];
    Object? lastError;
    for (final name in names) {
      try {
        return DynamicLibrary.open(name);
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('找不到 sodam_ffi.dll（先 cargo build --release）: $lastError');
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open(
      'rust/sodam-ffi/target/release/libsodam_ffi.dylib',
    );
  }
  return DynamicLibrary.open(
    'rust/sodam-ffi/target/release/libsodam_ffi.so',
  );
}

/// 符号不存在时返回 null（兼容旧版原生库）。
T? _lookupOrNull<T>(T Function(DynamicLibrary) lookup) {
  try {
    return lookup(_openedLibrary());
  } catch (_) {
    return null;
  }
}

DynamicLibrary _openedLibrary() => _libInstance ??= _open();
DynamicLibrary? _libInstance;

final class NativeFfi {
  NativeFfi._() {
    final lib = _openedLibrary();
    _init = lib.lookupFunction<_InitC, _InitDart>('sodam_init');
    _request =
        lib.lookupFunction<_RequestC, _RequestDart>('sodam_request');
    _free = lib.lookupFunction<_FreeC, _FreeDart>('sodam_free');
    // 签名桥符号（旧版桌面 dylib 可能没有：降级为空实现）。
    _signerPoll = _lookupOrNull(
        (lib) => lib.lookupFunction<_SignerPollC, _SignerPollDart>('sodam_signer_poll'));
    _signerRespond = _lookupOrNull(
        (lib) => lib.lookupFunction<_SignerRespondC, _SignerRespondDart>('sodam_signer_respond'));
    _secondVerifyData = _lookupOrNull(
        (lib) => lib.lookupFunction<_SecondVerifyC, _SecondVerifyDart>('sodam_second_verify_data'));
    _secondVerifyComplete = _lookupOrNull(
        (lib) => lib.lookupFunction<_SecondVerifyC, _SecondVerifyDart>('sodam_second_verify_complete'));
  }

  static final NativeFfi instance = NativeFfi._();

  late final _InitDart _init;
  late final _RequestDart _request;
  late final _FreeDart _free;
  _SignerPollDart? _signerPoll;
  _SignerRespondDart? _signerRespond;
  _SecondVerifyDart? _secondVerifyData;
  _SecondVerifyDart? _secondVerifyComplete;

  /// 配置全局会话。
  Map<String, dynamic> init(Map<String, dynamic> config) {
    final data = _invoke(() => _init(_encode(jsonEncode(config))));
    return data is Map<String, dynamic> ? data : const {};
  }

  /// 业务调用；返回 `data` 字段（形态由方法决定：对象或数组，如 suggest
  /// 返回字符串数组），失败抛 [SodamException]。
  dynamic request(String method, [Map<String, dynamic>? params]) {
    return _invoke(() => _request(
          _encode(method),
          _encode(params == null ? '' : jsonEncode(params)),
        ));
  }

  dynamic _invoke(Pointer<Utf8> Function() call) {
    final pointer = call();
    try {
      final text = pointer.toDartString();
      final value = jsonDecode(text);
      if (value is Map<String, dynamic> && value['ok'] == true) {
        return value['data'];
      }
      final error =
          value is Map<String, dynamic> ? value['error'] : '未知错误';
      throw SodamException(error?.toString() ?? '未知错误');
    } finally {
      _free(pointer);
    }
  }

  /// 取一条待签名请求；`{"id":""}` 表示空闲（原生侧不支持时同样返回空闲）。
  Map<String, dynamic> signerPoll() {
    final poll = _signerPoll;
    if (poll == null) return const {'id': ''};
    final data = _invoke(poll);
    return data is Map<String, dynamic> ? data : const {'id': ''};
  }

  /// 回填签名结果。
  void signerRespond(String json) {
    final respond = _signerRespond;
    if (respond == null) return;
    _invoke(() => respond(_encode(json)));
  }

  /// 二次验证窗口启动数据：`{decision, generalParams}`。
  Map<String, dynamic> secondVerifyData(String token) {
    final call = _secondVerifyData;
    final data = call == null
        ? null
        : _invoke(() => call(_encode(jsonEncode({'token': token}))));
    return data is Map<String, dynamic> ? data : const {};
  }

  /// 二次验证完成回执。
  void secondVerifyComplete(String token) {
    final call = _secondVerifyComplete;
    if (call == null) return;
    _invoke(() => call(_encode(jsonEncode({'token': token}))));
  }

  static Pointer<Utf8> _encode(String text) => text.toNativeUtf8();
}

class SodamException implements Exception {
  const SodamException(this.message);

  final String message;

  @override
  String toString() => message;
}
