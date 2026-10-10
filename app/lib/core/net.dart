/// 进程级共享 HttpClient：连接复用（keep-alive），封面/锁屏封面/直链
/// 下载共用。
///
/// 之前每处下载各自 `HttpClient()..close(force: true)`，列表里每张封面
/// 都要重新 DNS + TCP + TLS 握手（移动网络 1~3 个 RTT），网格页 20 张
/// 封面就是 20 次握手——这是图片加载慢的主要单因。共享实例让同 host
/// 连接跨请求复用（对齐官方客户端行为）。
///
/// 注意：拿到这个 client 的调用方**不要** close 它（进程生命周期内常驻）。

library;

import 'dart:io';

HttpClient? _shared;

/// 共享 HttpClient（懒创建；连接超时 15s，单 host 并发连接数 8）。
HttpClient get sharedHttpClient => _shared ??= () {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..maxConnectionsPerHost = 8;
      return client;
    }();
