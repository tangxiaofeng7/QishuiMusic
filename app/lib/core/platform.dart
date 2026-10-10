/// 原生能力桥（MethodChannel `sodam/platform`）：
/// openUrl / canOpenUrl / shareFile / deviceInfo——在线升级拉起 TrollStore
/// 安装、运行日志导出、交流群跳转、设置页运行环境展示。
///
/// 通道失败（原生侧未实现/异常）时 openUrl 返回 false、deviceInfo 返回
/// null，调用方回退到 dart:io 信息。

library;

import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('sodam/platform');

/// 系统能否处理该 URL scheme（判断 TrollStore 等安装器是否在）。
Future<bool> canOpenUrl(String url) async {
  if (!Platform.isIOS && !Platform.isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('canOpenUrl', {'url': url}) ??
        false;
  } catch (_) {
    return false;
  }
}

/// 打开外部 URL（安装 scheme / 跳转网页 / 交流群）。返回系统是否接受。
Future<bool> openUrl(String url) async {
  if (!Platform.isIOS && !Platform.isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
  } catch (_) {
    return false;
  }
}

/// 系统分享面板导出文件（运行日志 / 下载的安装包）。
Future<bool> shareFile(String path, {String? mimeType}) async {
  if (!Platform.isIOS) return false;
  try {
    return await _channel.invokeMethod<bool>('shareFile', {
          'path': path,
          'mimeType': mimeType,
        }) ??
        false;
  } catch (_) {
    return false;
  }
}

/// 设备运行环境（设置页展示）。键：
/// os / osVersion / model（iPhone、Pixel 8）/ machine（iPhone17,1、设备代号）
/// / simulator（"true"/"false"）。原生侧不可用时返回 null。
Future<Map<String, String>?> deviceInfo() async {
  if (!Platform.isIOS && !Platform.isAndroid) return null;
  try {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'deviceInfo',
    );
    if (raw == null) return null;
    return raw.map((key, value) => MapEntry('$key', '$value'));
  } catch (_) {
    return null;
  }
}
