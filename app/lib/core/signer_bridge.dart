/// App 内置签名页：隐藏 WebView + loopback HTTP 服务（静态资产 + 同源中继）。
///
/// 取代旧版「远程签名页服务」（browserSignerUrl）：
/// * 资产（官方安全组件 sdk-glue / bdms 快照）随 App 打包；
/// * 页面由本机 `http://127.0.0.1:<port>/` 承载；
/// * WKWebView 没有桌面 Chromium 的 `--disable-web-security`，跨域带凭据
///   XHR 会被 CORS 拒绝——因此页面把 api.qishui.com 的请求改写成同源路径
///   （host.html 的 XHR open 改写器，在 bdms 加载前安装，签名仍基于真实
///   URL），由本服务原生转发到 api.qishui.com，并维护 Cookie 罐；
/// * Rust 侧（libresoda 的 BrowserRequester）通过 `sodam_signer_poll/respond`
///   把待签名请求交到这里，本服务在签名页里执行 `__sodamCall` 后回填。
///
/// WebView 必须挂在 widget 树上才会执行 JS：`QishuiApp` 里用
/// [SignerBridgeView] 以 1x1 的形式常驻。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'ffi.dart';
import 'logging.dart';
import 'store.dart'
    show appContainerRoot, lxUserScriptsDirPath;

/// 全局 Navigator 键：二次验证窗口需要从无 BuildContext 的签名桥弹出。
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class SignerBridge {
  SignerBridge._();

  static final SignerBridge instance = SignerBridge._();

  static const _channelName = 'SodaSigner';

  /// 本地资产（其余路径一律按中继处理）。value 是 flutter_assets 里的
  /// 完整目录（signer/、lx/、lx-sources/），不再假定都在 signer/ 下。
  static const _assets = {
    '/': 'signer/host.html',
    '/host.html': 'signer/host.html',
    '/verify.html': 'signer/verify.html',
    '/lx/runtime.html': 'lx/runtime.html',
    '/lx/frame.html': 'lx/frame.html',
    '/react.js': 'signer/react.js',
    '/react-dom.js': 'signer/react-dom.js',
    '/sdk-glue.js': 'signer/sdk-glue.js',
    '/bdms.js': 'signer/bdms.js',
  };

  /// loopback 基地址（如 http://127.0.0.1:56123/）；未启动时为空。
  String get baseUri {
    final server = _server;
    if (server == null) return '';
    return 'http://${server.address.address}:${server.port}/';
  }

  HttpServer? _server;
  Future<void>? _starting;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12);
  WebViewController? controller;
  bool _pageReady = false;
  bool _polling = false;
  String _lastError = '';

  /// Cookie 罐（.qishui.com 域，name → value）：中继响应的 Set-Cookie 在这里
  /// 累积，既是后续中继请求的凭据，也是扫码成功后回填给 Rust 的会话来源。
  final Map<String, String> _cookies = {};

  final Completer<void> _controllerReady = Completer<void>();

  /// controller 挂载完成（widget 此时可以 rebuild 拿到 WebView）。
  Future<void> get controllerReady => _controllerReady.future;

  /// 签名页当前是否可用（bdms 已加载）。
  bool get isReady => _pageReady;

  String get lastError => _lastError;

  /// 当前 Cookie 罐内容（诊断/设置页展示用）。
  Map<String, String> get cookies => Map.unmodifiable(_cookies);

  /// 启动 loopback 服务并预载签名页；失败不抛（登录时再提示）。
  /// 并发调用共享同一次启动（签名页视图与 lx 运行时视图首帧同时触发）。
  Future<void> ensureStarted() => _starting ??= _startOnce();

  Future<void> _startOnce() async {
    try {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      _server = server;
      unawaited(_serve(server));
      unawaited(_boot());
      appLog(
        'signer: loopback server on ${server.address.address}:${server.port}',
      );
    } catch (error) {
      _lastError = '签名页服务启动失败: $error';
      appLog('signer: $_lastError');
      _starting = null; // 失败允许重试
    }
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      final path = request.uri.path;
      final asset = _assets[path];
      if (asset != null) {
        await _serveAsset(request, asset);
      } else if (path.startsWith('/lx-sources/')) {
        // lx 脚本：用户导入的文件优先（可编辑、可更新），内置资产兜底
        // （assets/lx-sources/<name>.js，仅推荐音源导入内容与旧会话引用）。
        final name = request.uri.pathSegments.last;
        if (RegExp(r'^[A-Za-z0-9_-]+\.js$').hasMatch(name)) {
          if (!await _serveUserLxScript(request, name) &&
              !await _serveAsset(request, 'lx-sources/$name')) {
            request.response.statusCode = 404;
            await request.response.close();
          }
        } else {
          request.response.statusCode = 404;
          await request.response.close();
        }
      } else if (path.startsWith('/verify/')) {
        await _serveVerify(request);
      } else {
        await _relay(request);
      }
    }
  }

  Future<bool> _serveAsset(HttpRequest request, String name) async {
    try {
      final data = await rootBundle.load('assets/$name');
      final bytes = data.buffer.asUint8List();
      final type = name.endsWith('.js')
          ? 'application/javascript; charset=utf-8'
          : 'text/html; charset=utf-8';
      request.response.headers.contentType = ContentType.parse(type);
      request.response.add(bytes);
      await request.response.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 用户自定义 lx 脚本（应用容器 `Documents/lx_sources/<name>.js`）。no-store：
  /// 内容可被编辑后重载，不能让 WebView 缓存住旧版本。
  /// 服务用户脚本文件；文件不存在返回 false（交回调用方兜底，不碰响应）。
  Future<bool> _serveUserLxScript(HttpRequest request, String name) async {
    try {
      final root = await appContainerRoot();
      final file = File('${lxUserScriptsDirPath(root)}/$name');
      if (!file.existsSync()) return false;
      final bytes = file.readAsBytesSync();
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.response.headers.contentType = ContentType.parse(
        'application/javascript; charset=utf-8',
      );
      request.response.add(bytes);
      await request.response.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 中继上游白名单（passport 流程涉及的汽水/抖音/字节系域名）。
  /// mcs/mon.zijieapi.com：bdms 设备注册（webid/tobid），不放行会挂死签名页。
  static const _hostWhitelist = {
    'api.qishui.com',
    'www.qishui.com',
    'bff-pc.qishui.com',
    'auth.zijieapi.com',
    'mcs.zijieapi.com',
    'mon.zijieapi.com',
    'sso.douyin.com',
    'www.douyin.com',
    'qishui.douyin.com',
    'aweme.snssdk.com',
    'lf-headquarters-speed.yhgfb-cn-static.com',
    'lf-c-flwb.bytetos.com',
  };

  /// 把页面的同源请求转发到 `https://<__sodam_host>/<原路径>`（无 CORS 概念），
  /// 请求带 Cookie 罐，响应的 Set-Cookie 并回罐里。
  /// 页面侧的 XHR 改写器会把真实域名放进 `__sodam_host` 查询参数——bdms
  /// 签名看到的是真实 URL，这里剥掉该参数后转发，服务端收到的与签名一致。
  Future<void> _relay(HttpRequest request) async {
    try {
      final query = Map<String, String>.from(request.uri.queryParameters);
      final host = query.remove('__sodam_host') ?? 'api.qishui.com';
      // lx 用户脚本运行时的代发请求（__sodam_lx=1）放行任意上游域：
      // loopback 仅进程内可达，脚本自身的目标域无法预知（各家 API/CDN）。
      final isLx = query.remove('__sodam_lx') == '1';
      if (!_hostWhitelist.contains(host) && !isLx) {
        request.response.statusCode = 403;
        await request.response.close();
        appLog('signer: relay 拒绝非白名单域: $host');
        return;
      }
      final rebuilt = Uri(queryParameters: query.isNotEmpty ? query : null);
      final upstreamUri = Uri.https(
        host,
        request.uri.path,
        query.isNotEmpty ? rebuilt.queryParametersAll : null,
      );
      final clientRequest = await _client.openUrl(request.method, upstreamUri);
      // 透传页面设置的头部（Content-Type / X-SS-STUB / x-tt-passport-* 等），
      // 浏览器自加的连接层头部交给 dart:io 自己管。User-Agent 必须透传：
      // WebView 全局 UA 就是官方客户端 UA（签名按它计算），丢掉的话
      // dart:io 请求就没有 UA——服务端风控据此限流（error_code=7）。
      const skip = {
        'host',
        'cookie',
        'origin',
        'referer',
        'content-length',
        'connection',
        'accept-encoding',
      };
      request.headers.forEach((name, values) {
        if (!skip.contains(name.toLowerCase())) {
          clientRequest.headers.set(name, values);
        }
      });
      if (_cookies.isNotEmpty) {
        clientRequest.headers.set(
          'cookie',
          _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
        );
      }
      // body
      final body = await request.fold<List<int>>(
        <int>[],
        (prev, chunk) => prev..addAll(chunk),
      );
      if (body.isNotEmpty) clientRequest.add(body);
      final response = await clientRequest.close();
      final responseBody = await response.fold<List<int>>(
        <int>[],
        (prev, chunk) => prev..addAll(chunk),
      );

      // Set-Cookie → 罐（只取 name=value；空值视为删除）。
      var cookiesChanged = false;
      for (final raw
          in response.headers[HttpHeaders.setCookieHeader] ?? const []) {
        final pair = raw.split(';').first.trim();
        final eq = pair.indexOf('=');
        if (eq <= 0) continue;
        final name = pair.substring(0, eq).trim();
        final value = pair.substring(eq + 1).trim();
        if (value.isEmpty) {
          cookiesChanged |= _cookies.remove(name) != null;
        } else {
          cookiesChanged |= _cookies[name] != value;
          _cookies[name] = value;
        }
      }
      // 服务端轮换的 Cookie（msToken 等）同步进 WebView 的 Cookie 存储
      // （页面源 127.0.0.1）：bdms 签名时会读 document.cookie，官方网页流程
      // 里 msToken 的轮换就是靠这个反馈闭环——不同步会被风控按陈旧令牌限流。
      if (cookiesChanged) {
        unawaited(_syncCookiesToWebView());
      }

      final reply = request.response;
      reply.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        final lower = name.toLowerCase();
        // set-cookie 进 Cookie 罐不透传；content-length/transfer-encoding 由
        // dart:io 重算；content-encoding 必须去掉——HttpClient 已自动解压，
        // 再透传会让 WebView 按 gzip 解码明文而报 network error。
        if (lower == HttpHeaders.setCookieHeader) return;
        if (lower == 'content-length') return;
        if (lower == 'transfer-encoding') return;
        if (lower == 'content-encoding') return;
        reply.headers.set(name, values);
      });
      reply.add(responseBody);
      await reply.close();
      final preview = const Utf8Decoder(
        allowMalformed: true,
      ).convert(responseBody.take(400).toList());
      // 记录完整查询串：验证 bdms 是否真的追加了 a_bogus/msToken，
      // msToken 只记尾 4 位——足够观察轮换，不泄完整令牌。
      final hasBogus = request.uri.query.contains('a_bogus');
      final msTokenTail = RegExp(
        r'[?&]msToken=([^&]{4})[^&]*',
      ).firstMatch(request.uri.query)?.group(1);
      appLog(
        'signer: relay-v4 ${request.method} $host${request.uri.path} '
        'a_bogus=$hasBogus msToken=${msTokenTail == null ? 'none' : '****$msTokenTail'} '
        '-> ${response.statusCode} (${responseBody.length}B, cookies=${_cookies.length}) '
        'body[:400]=$preview',
      );
    } catch (error) {
      appLog('signer: relay 失败 ${request.method} ${request.uri.path}: $error');
      try {
        request.response.statusCode = 502;
        request.response.add(utf8.encode('relay error: $error'));
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 把 Dart 侧 Cookie 罐镜像到 WebView 的 Cookie 存储（127.0.0.1 页面源），
  /// 让签名页里的 bdms 能读到服务端轮换后的 msToken（document.cookie）。
  Future<void> _syncCookiesToWebView() async {
    final server = _server;
    if (server == null || _cookies.isEmpty) return;
    final host = server.address.address;
    try {
      final manager = WebViewCookieManager();
      for (final entry in _cookies.entries) {
        await manager.setCookie(
          WebViewCookie(
            name: entry.key,
            value: entry.value,
            domain: host,
            path: '/',
          ),
        );
      }
    } catch (error) {
      appLog('signer: Cookie 同步进 WebView 失败(忽略): $error');
    }
  }

  // ---------------------------------------------------------------------------
  // 二次验证窗口（check_qrconnect 返回 2046 时弹出；桌面版 security_host
  // 的同源移植：页面加载官方 ucWebSecondVerify 组件，网络请求经
  // /verify/request 转发进签名页（带 bdms 签名 + 中继），完成回执经
  // /verify/complete 置位，轮询侧随即重发确认）。
  // ---------------------------------------------------------------------------

  /// 验证页代发请求的在途等待表（id → completer）。
  final Map<String, Completer<Map<String, dynamic>>> _verifyWaiters = {};

  /// 最近一次验证代发请求的时间：bdms 给高危请求签名会同步阻塞签名页
  /// JS 长达 30s+（期间轮询全部超时是正常现象），此时绝不能重载签名页
  /// ——会把在途签名连根拆掉，组件端表现为「操作失败」。
  DateTime? _lastVerifyActivity;

  /// 是否有验证代发请求在途。
  bool get hasPendingVerifyRequests => _verifyWaiters.isNotEmpty;

  /// 验证窗口当前 token（防重复弹窗）。
  String? _verifyWindowToken;

  Future<void> _serveVerify(HttpRequest request) async {
    final path = request.uri.path;
    try {
      if (path == '/verify/done') {
        request.response.headers.contentType = ContentType.html;
        request.response.add(
          utf8.encode(
            '<!doctype html><meta charset="utf-8"><body>'
            '<p style="font-family:sans-serif;text-align:center;margin-top:40vh">'
            '验证完成，正在返回…</p>',
          ),
        );
        await request.response.close();
        return;
      }
      final body = await request.fold<List<int>>(
        <int>[],
        (prev, chunk) => prev..addAll(chunk),
      );
      final value = body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      if (path == '/verify/start') {
        final token =
            value['token']?.toString() ?? value['key']?.toString() ?? '';
        appLog(
          'signer: verify/start 收到 token(len=${token.length} '
          '尾…${token.length > 8 ? token.substring(token.length - 8) : token})',
        );
        final data = NativeFfi.instance.secondVerifyData(token);
        final decision = data['decision'];
        if (decision == null) {
          await _replyJson(request, {
            'success': false,
            'error': data.isEmpty ? '二次验证会话不存在' : '未取到验证决策',
          });
          return;
        }
        await _replyJson(request, {
          'success': true,
          'data': {
            'decision': decision,
            'generalParams': data['generalParams'] ?? const {},
          },
        });
        return;
      }
      if (path == '/verify/request') {
        final token =
            value['token']?.toString() ?? value['key']?.toString() ?? '';
        final spec = value['request'];
        if (spec is! Map) {
          await _replyJson(request, {'ok': false, 'error': '缺少 request 字段'});
          return;
        }
        appLog(
          'signer: verify 请求 ${spec['method']} '
          '${(spec['url']?.toString() ?? '').split('?').first}',
        );
        final result = await _verifyRelayRoundtrip(token, spec);
        appLog(
          'signer: verify 应答 ${spec['method']} '
          '${(spec['url']?.toString() ?? '').split('?').first} -> '
          '${result['status']} (${result['error'] ?? 'ok'})',
        );
        await _replyJson(request, result);
        return;
      }
      if (path == '/verify/log') {
        // 验证页的请求观测信标（method+host+path），进应用日志。
        appLog(
          'signer: verify 页面请求 ${value['kind']} ${value['method']} '
          '${value['host']}${value['path']}',
        );
        await _replyJson(request, {'success': true});
        return;
      }
      if (path == '/verify/complete') {
        final token =
            value['token']?.toString() ?? value['key']?.toString() ?? '';
        NativeFfi.instance.secondVerifyComplete(token);
        appLog(
          'signer: 二次验证完成回执 (token=…${token.length > 8 ? token.substring(token.length - 8) : token})',
        );
        await _replyJson(request, {'success': true});
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    } catch (error) {
      appLog('signer: verify 端点失败 $path: $error');
      try {
        await _replyJson(request, {'ok': false, 'error': '$error'});
      } catch (_) {}
    }
  }

  Future<void> _replyJson(
    HttpRequest request,
    Map<String, dynamic> value,
  ) async {
    request.response.headers.contentType = ContentType.json;
    request.response.add(utf8.encode(jsonEncode(value)));
    await request.response.close();
  }

  /// 把验证组件的网络请求转发进签名页执行（带 bdms 签名 + 同源中继）。
  Future<Map<String, dynamic>> _verifyRelayRoundtrip(
    String token,
    Map spec,
  ) async {
    final controller = this.controller;
    if (controller == null || !_pageReady) {
      return {'ok': false, 'status': 0, 'error': '签名页未就绪'};
    }
    final id = 'verify-req-${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<Map<String, dynamic>>();
    _verifyWaiters[id] = completer;
    _lastVerifyActivity = DateTime.now();
    final script =
        'window.__sodamCall(${jsonEncode(id)}, ${jsonEncode(jsonEncode(spec))})';
    try {
      await controller.runJavaScript(script);
    } catch (error) {
      _verifyWaiters.remove(id);
      return {'ok': false, 'status': 0, 'error': '签名页执行失败: $error'};
    }
    final result = await completer.future.timeout(
      // bdms 给高危请求（发短信/验证码）签名可能要 30s+（内部有重试/
      // 设备凭证建立），实测 30s 超时会刚好错过响应——必须放宽。
      const Duration(seconds: 150),
      onTimeout: () {
        _verifyWaiters.remove(id);
        // 签名页疑似卡死（bdms 签名队列挂起）：重载页面自愈。
        appLog('signer: verify 桥接超时，重载签名页自愈');
        unawaited(reloadSignerPage());
        return {'ok': false, 'status': 0, 'error': '签名请求超时（已重启签名页，请重试）'};
      },
    );
    return result;
  }

  /// 重载签名页（签名队列卡死自愈；带冷却防止循环重载）。
  /// 验证请求在途或近 3 分钟内有验证活动时跳过——bdms 签名期间页面的
  /// 阻塞是正常的，重载只会杀死在途请求。
  DateTime? _lastReload;
  Future<void> reloadSignerPage() async {
    if (hasPendingVerifyRequests) {
      appLog('signer: 跳过签名页重载（有 ${_verifyWaiters.length} 个验证请求在途）');
      return;
    }
    final lastActivity = _lastVerifyActivity;
    if (lastActivity != null &&
        DateTime.now().difference(lastActivity) < const Duration(minutes: 3)) {
      appLog(
        'signer: 跳过签名页重载（${lastActivity.toIso8601String()} 有验证活动，疑似签名阻塞期）',
      );
      return;
    }
    if (_lastReload != null &&
        DateTime.now().difference(_lastReload!) < const Duration(seconds: 20)) {
      return;
    }
    _lastReload = DateTime.now();
    _pageReady = false;
    final server = _server;
    final controller = this.controller;
    if (server == null || controller == null) return;
    try {
      await controller.loadRequest(
        Uri.parse('http://${server.address.address}:${server.port}/'),
      );
      await _waitForBdms();
      appLog('signer: 签名页已重载并就绪');
    } catch (error) {
      appLog('signer: 签名页重载失败: $error');
    }
  }

  /// 弹出可见的二次验证窗口（fullscreen；由 Rust 2046 登记通知触发）。
  void openSecondVerifyWindow(String token) {
    if (_verifyWindowToken == token) return; // 窗口已开
    _verifyWindowToken = token;
    final server = _server;
    if (server == null) {
      _verifyWindowToken = null;
      return;
    }
    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      _verifyWindowToken = null;
      appLog('signer: 无法弹出验证窗口（navigator 不可用）');
      return;
    }
    appLog('signer: 弹出二次验证窗口 (token=…${token.substring(token.length - 8)})');
    navigator.push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => SecondVerifyPage(
          url:
              'http://${server.address.address}:${server.port}/verify.html?key=${Uri.encodeQueryComponent(token)}',
          onClosed: () => _verifyWindowToken = null,
        ),
      ),
    );
  }

  /// 官方桌面客户端内嵌浏览器 UA（qr_login 的 a_bogus 按它校验）。
  /// WebKit 会静默忽略 XHR 的 User-Agent 头，必须全局设置 WebView UA，
  /// 否则请求带 Safari UA 而签名按官方 UA 计算，服务端判签名无效 → 限流。
  static const officialUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like '
      'Gecko) SodaMusic/3.2.1 Chrome/136.0.7103.59 Electron/36.4.0 Safari/537.36';

  Future<void> _boot() async {
    final server = _server;
    if (server == null) return;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(officialUserAgent)
      ..addJavaScriptChannel(_channelName, onMessageReceived: _onPageMessage)
      ..setNavigationDelegate(
        NavigationDelegate(onPageFinished: (_) => unawaited(_waitForBdms())),
      )
      ..loadRequest(
        Uri.parse('http://${server.address.address}:${server.port}/'),
      );
    this.controller = controller;
    if (!_controllerReady.isCompleted) {
      _controllerReady.complete();
    }
  }

  Future<void> _waitForBdms() async {
    final controller = this.controller;
    if (controller == null || _pageReady) return;
    for (var i = 0; i < 60 && !_pageReady; i++) {
      try {
        final ready = await controller.runJavaScriptReturningResult(
          'window.__sodamReady ? window.__sodamReady() : false',
        );
        if (ready.toString() == 'true') {
          _pageReady = true;
          _lastError = '';
          appLog('signer: bdms ready (${i * 500}ms)');
          unawaited(_runPollLoop());
          return;
        }
      } catch (_) {
        // 页面还没装载完，继续等
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!_pageReady && _lastError.isEmpty) {
      _lastError = '签名组件加载超时（bdms 未就绪）';
      appLog('signer: $_lastError');
    }
  }

  /// 签名页 → Dart：一条签名请求的执行结果（附上 Cookie 罐）。
  void _onPageMessage(JavaScriptMessage message) {
    try {
      final value = jsonDecode(message.message) as Map<String, dynamic>;
      final id = value['id']?.toString() ?? '';
      if (id.isEmpty) return;
      // 验证窗口的代发请求：直接完成等待方，不进 Rust 回填。
      final waiter = _verifyWaiters.remove(id);
      if (waiter != null && !waiter.isCompleted) {
        final result = value['result'];
        waiter.complete(
          result is Map<String, dynamic> ? result : const <String, dynamic>{},
        );
        return;
      }
      if (id.startsWith('verify-req-')) {
        appLog('signer: 迟到的验证响应无人认领（id=$id，等待方已超时）');
        return;
      }
      final result = value['result'];
      final payload = <String, dynamic>{
        'id': id,
        'ok': true,
        'response': result ?? const <String, dynamic>{},
      };
      // 回填 Cookie 罐：扫码成功后 Rust 侧从这里收割会话。
      if (_cookies.isNotEmpty) {
        payload['response'] = {
          ...(result as Map<String, dynamic>? ?? const {}),
          'cookies': [
            for (final entry in _cookies.entries)
              {
                'name': entry.key,
                'value': entry.value,
                'domain': '.qishui.com',
              },
          ],
        };
      }
      _respond(payload);
    } catch (error) {
      appLog('signer: 页面消息解析失败: $error');
    }
  }

  void _respond(Map<String, dynamic> payload) {
    final ffi = NativeFfi.instance;
    try {
      ffi.signerRespond(jsonEncode(payload));
    } catch (error) {
      appLog('signer: respond 失败: $error');
    }
  }

  /// Dart → Rust：轮询待签名请求，分发到签名页。
  Future<void> _runPollLoop() async {
    if (_polling) return;
    _polling = true;
    final ffi = NativeFfi.instance;
    while (_polling) {
      Map<String, dynamic> pending;
      try {
        pending = ffi.signerPoll();
      } catch (error) {
        appLog('signer: poll 失败: $error');
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      final id = pending['id']?.toString() ?? '';
      if (id.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        continue;
      }
      // 2046 二次验证通知：弹可见验证窗口（不是签名请求，不进页面）。
      final request = pending['request'];
      if (request is Map && request['type'] == 'secondVerify') {
        final token = request['token']?.toString() ?? '';
        if (token.isNotEmpty) {
          openSecondVerifyWindow(token);
        }
        continue;
      }
      await _dispatch(id, pending['request']);
    }
  }

  Future<void> _dispatch(String id, dynamic request) async {
    final controller = this.controller;
    if (controller == null || !_pageReady) {
      _respond({
        'id': id,
        'ok': false,
        'error': _lastError.isEmpty ? '签名页未就绪' : _lastError,
      });
      return;
    }
    final spec = jsonEncode(request ?? const <String, dynamic>{});
    final script = 'window.__sodamCall(${jsonEncode(id)}, ${jsonEncode(spec)})';
    try {
      await controller.runJavaScript(script);
    } catch (error) {
      _respond({'id': id, 'ok': false, 'error': '签名页执行失败: $error'});
    }
  }

  /// 重置签名页会话（等价桌面签名器的「每会话独立浏览器上下文」）：
  /// 清空 Cookie 罐与 WebView 存储、重载页面。生成新登录二维码前调用，
  /// 避免共用设备身份被 passport 按设备限流（error_code=7）。
  Future<void> resetSession() async {
    _cookies.clear();
    final controller = this.controller;
    if (controller != null) {
      try {
        await WebViewCookieManager().clearCookies();
      } catch (_) {}
      try {
        // 清 bdms 的本地身份（msToken 等落在 localStorage）。
        await controller.runJavaScript(
          'try { localStorage.clear(); sessionStorage.clear(); } catch (e) {}',
        );
      } catch (_) {}
      final server = _server;
      if (server != null) {
        _pageReady = false;
        await controller.loadRequest(
          Uri.parse('http://${server.address.address}:${server.port}/'),
        );
        await _waitForBdms();
      }
    }
    appLog('signer: session reset (cookies=${_cookies.length})');
  }

  void dispose() {
    _polling = false;
    _server?.close(force: true);
    _server = null;
    controller = null;
    _pageReady = false;
    _client.close(force: true);
  }
}

/// 常驻的 1x1 隐藏签名 WebView（挂在 widget 树上才会执行 JS）。
class SignerBridgeView extends StatefulWidget {
  const SignerBridgeView({super.key});

  @override
  State<SignerBridgeView> createState() => _SignerBridgeViewState();
}

class _SignerBridgeViewState extends State<SignerBridgeView> {
  @override
  void initState() {
    super.initState();
    unawaited(
      SignerBridge.instance
          .ensureStarted()
          .then((_) {
            return SignerBridge.instance.controllerReady;
          })
          .then((_) {
            if (mounted) setState(() {});
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = SignerBridge.instance.controller;
    if (controller == null) return const SizedBox.shrink();
    return SizedBox(
      width: 1,
      height: 1,
      child: WebViewWidget(controller: controller),
    );
  }
}

/// 可见的二次验证窗口（fullscreen）：加载 /verify.html，官方组件在里面
/// 渲染 MFA 验证 UI；完成/过期后导航到 /verify/done，这里自动关闭。
class SecondVerifyPage extends StatefulWidget {
  const SecondVerifyPage({super.key, required this.url, this.onClosed});

  final String url;
  final VoidCallback? onClosed;

  @override
  State<SecondVerifyPage> createState() => _SecondVerifyPageState();
}

class _SecondVerifyPageState extends State<SecondVerifyPage> {
  late final WebViewController _controller;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(SignerBridge.officialUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (request.url.endsWith('/verify/done') && !_closing) {
              _closing = true;
              appLog('signer: 验证窗口流程完成，关闭');
              Future<void>.microtask(() => _close());
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  void _close() {
    widget.onClosed?.call();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('身份验证'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: _close),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
