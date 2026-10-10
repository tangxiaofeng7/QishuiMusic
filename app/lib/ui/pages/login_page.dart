import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api.dart';
import '../../core/errors.dart';
import '../../core/logging.dart';
import '../../core/store.dart';
import '../../main.dart';
import '../../core/signer_bridge.dart';

/// 登录页：扫码登录（主路径）/ Cookie 登录（兜底）。
///
/// 2026-10 改造：
/// * 移除「网页登录」（官网已无登录入口、登录组件仅剩 SDK 桥接页）；
/// * 扫码不再依赖远程签名页 —— `a_bogus` 网页签名由 App 内置签名页
///   （隐藏 WebView 跑官方 bdms 安全组件）提供，轮询不会被限流；
/// * 官方 App 的「抖音一键登录」走开放平台 SDK + 已注册的回跳域名 +
///   签名换票（`/passport/auth/share_login/`），第三方 App 无法复刻
///   （收不到回跳授权码），扫码 + 官方汽水 App 确认是等价的零依赖路径。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录汽水音乐'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(text: '扫码登录'),
            Tab(text: 'Cookie 登录'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [_QrLoginTab(), _CookieLoginTab()],
      ),
    );
  }
}

/// 登录成功的收尾：保存 Cookie、重建 Rust 会话、关页。
Future<void> _saveCookieAndFinish(BuildContext context, String cookie) async {
  appLog('login: 保存会话 cookie（${cookie.length} 字）');
  settings.cookie = cookie;
  await settings.save();
  final cacheDir = await Settings.resolveCacheDir();
  await Api.configure(settings.toFfiConfig(cacheDir));
  // 登录后把账号喜欢列表并进全局喜欢存储（并集，本地新增不丢）
  unawaited(likedStore.refreshFromServer());
  appLog('login: 会话已重建（hasCookie=${settings.hasCookie}）');
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('登录成功')));
    Navigator.of(context).pop(true);
  }
}

// ---------------------------------------------------------------------------
// 扫码登录（官方汽水 App 扫码确认；签名由内置签名页补齐）
// ---------------------------------------------------------------------------

class _QrLoginTab extends StatefulWidget {
  const _QrLoginTab();

  @override
  State<_QrLoginTab> createState() => _QrLoginTabState();
}

class _QrLoginTabState extends State<_QrLoginTab> {
  String? _scanUrl;
  String? _token;
  String _status = '';
  Timer? _timer;
  bool _busy = false;
  int _errorStreak = 0;
  int _rateLimitStreak = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_create());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      // 签名页冷启动（首次加载 bdms 安全组件）可能要几秒，先等就绪；
      // 每个新二维码配一个干净签名会话（等价桌面签名器的独立浏览器上下文，
      // 避免共用设备身份被 passport 按设备限流）。
      await SignerBridge.instance.ensureStarted();
      await SignerBridge.instance.resetSession();
      final qr = await Api.qrCreate();
      if (!mounted) return;
      setState(() {
        _scanUrl = qr.scanUrl;
        _token = qr.token;
        _status = '请用手机上的「汽水音乐」App 扫码';
      });
      _timer?.cancel();
      // 5s 轮询：无签名时服务端只容忍约十次 check，再快只会更早触发限流
      // （Rust 侧另有 error_code=7 的指数退避兜底）。
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => _check(qr.token));
    } catch (error) {
      if (mounted) {
        setState(() => _status = friendlyError('$error'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check(String token) async {
    try {
      final result = await Api.qrCheck(token);
      _errorStreak = 0;
      appLog('qr: check status=${result.status} extra=${result.extra}');
      if (!mounted) return;
      if (result.rateLimited) {
        _rateLimitStreak++;
        // 连续限流：不再自动重开二维码（每张新码都要重新消耗 IP 额度，
        // 只会延长封锁）。改为静默等待 Rust 侧的渐进退避（5s→30s）自然
        // 恢复；二维码真的过期会走 expired 分支重新生成。
        appLog('qr: 限流第 $_rateLimitStreak 次，等待退避恢复');
        if (_rateLimitStreak >= 6) {
          setState(() => _status = '服务端限流中（已 $_rateLimitStreak 次），正在按退避自动重试，请勿关闭本页…');
        } else {
          setState(() => _status = '被限流，稍后自动重试…');
        }
        return;
      }
      _rateLimitStreak = 0;
      setState(() => _status = result.message);
      switch (result.status) {
        case 'success':
          _timer?.cancel();
          appLog('qr: 登录成功，正在保存会话');
          await _saveCookieAndFinish(context, result.cookie);
        case 'expired':
        case 'failed':
          _timer?.cancel();
          appLog('qr: ${result.status}（${result.message}），二维码作废');
          setState(() => _scanUrl = null);
        case 'waiting':
        case 'scanned':
          break;
      }
      if (result.needSecondVerify && mounted) {
        // 二次验证窗口一般会自动弹出；这里兜底提供手动入口
        // （窗口被误关/弹窗失败时用户仍能继续）。
        if (!(_status.contains('手动') || _status.contains('打开'))) {
          setState(() => _status =
              '${result.message}；若验证窗口未出现，请点下方「打开验证窗口」');
        }
      }
    } catch (error) {
      // 连续失败要可见（此前静默吞掉，UI 会永远停在上一条状态）。
      _errorStreak++;
      appLog('qr: check 异常: $error');
      // 连续超时多半是签名页的 bdms 队列挂起（如设备注册被拦后签名死锁）：
      // 重载签名页自愈一次。
      if (_errorStreak == 3 && error.toString().contains('签名页超时')) {
        appLog('qr: 连续签名页超时，重载签名页自愈');
        unawaited(SignerBridge.instance.reloadSignerPage());
      }
      if (!mounted) return;
      if (_errorStreak >= 3) {
        setState(() => _status = '轮询出错（$_errorStreak 次）：$error');
      }
      if (_errorStreak >= 10) {
        _timer?.cancel();
        setState(() {
          _status = '轮询连续失败，已停止。请点「刷新二维码」重试：$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Center(
          child: _scanUrl == null
              ? (_busy
                  ? const CircularProgressIndicator()
                  : Column(
                      children: [
                        const SizedBox(height: 20),
                        Text(_status.isEmpty ? '二维码未生成' : _status),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          onPressed: _create,
                          child: const Text('重新生成'),
                        ),
                      ],
                    ))
              : Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: _scanUrl!,
                    size: 240,
                    backgroundColor: Colors.white,
                  ),
                ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            _status,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.outline),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: _create,
            child: const Text('刷新二维码'),
          ),
        ),
        Center(
          child: TextButton(
            onPressed: _token == null
                ? null
                : () => SignerBridge.instance.openSecondVerifyWindow(_token!),
            child: const Text('打开验证窗口'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            '提示：手机装了官方「汽水音乐」App 才能扫码确认（抖音账号登录的官方'
            ' App 直接确认即可）；也可以把这张二维码截图后，在官方 App 的扫一扫'
            '里选择「相册识别」。签名由 App 内置签名页提供，无需任何外部服务。',
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Cookie 粘贴
// ---------------------------------------------------------------------------

class _CookieLoginTab extends StatefulWidget {
  const _CookieLoginTab();

  @override
  State<_CookieLoginTab> createState() => _CookieLoginTabState();
}

class _CookieLoginTabState extends State<_CookieLoginTab> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final cookie = _controller.text.trim();
    if (cookie.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 先验证 Cookie 有效
      settings.cookie = cookie;
      final cacheDir = await Settings.resolveCacheDir();
      await Api.configure(settings.toFfiConfig(cacheDir));
      final account = await Api.account();
      await settings.save();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
              SnackBar(content: Text('登录成功：${account.nickname}')));
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      setState(() => _error = error.toString());
      // 回滚，避免残留无效 Cookie
      settings.cookie = '';
      await settings.save();
      final cacheDir = await Settings.resolveCacheDir();
      await Api.configure(settings.toFfiConfig(cacheDir));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          controller: _controller,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: '汽水音乐 Cookie',
            hintText: 'sessionid_ss=...; sid_tt=...; ...',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        FilledButton(
          onPressed: _busy ? null : _apply,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('登录'),
        ),
        const SizedBox(height: 16),
        Text(
          '获取方式（任选其一）：\n'
          '1. 官方汽水音乐 App 所在手机（需越狱）读取会话；\n'
          '2. 电脑安装桌面版 SodaM，登录后复制设置里的 Cookie；\n'
          '3. 浏览器登录汽水网页后，开发者工具里复制 Cookie。\n'
          '要求至少包含 sessionid_ss / sid_guard 之一的完整会话。',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ],
    );
  }
}
