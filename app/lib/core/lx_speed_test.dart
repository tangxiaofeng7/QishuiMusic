/// lx 单脚本端到端测试（推荐音源行的「测试」与脚本详情页共用）。
///
/// 口径对齐播放行为：加载脚本 → 按其支持的平台搜索测试曲 →
/// musicUrl 出链 → Range 探测直链可达。结果写 speedStore（列表页
/// 延迟徽标与按延迟排序共用）。原「全量测速编排 + 首启引导弹窗」
/// 已按用户要求移除（2026-10-10）：测速入口收敛到推荐音源行与
/// 脚本详情页，逐个测试、按需导入。

library;

import 'api.dart';
import 'lx_runtime.dart';
import 'speed.dart';
import 'store.dart' as store;

/// 每脚本延迟的 speedStore key（列表徽标与详情页共用）。
String lxSpeedKey(String scriptId) => 'lx/$scriptId';

/// 单脚本测试结果。
class LxScriptTestResult {
  const LxScriptTestResult({
    required this.ok,
    required this.ms,
    required this.text,
  });

  /// 端到端可用（出链 + 直链探测均通过）。
  final bool ok;

  /// 总耗时（含加载；未就绪时首次测试含初始化）。
  final int ms;

  /// 结果描述（成功 = 延迟；失败 = 原因）。
  final String text;
}

class LxScriptTest {
  LxScriptTest._();

  /// 端到端测试一个脚本：未就绪先加载（最长 15s）→ 按脚本支持的
  /// 平台搜索「周杰伦 晴天」（当前曲库平台优先）→ 出链（8s 上限）→
  /// 直链探测（3s）。结果回写 speedStore 并返回。
  static Future<LxScriptTestResult> testScript(String scriptId) async {
    final stopwatch = Stopwatch()..start();
    final script = LxRuntime.instance.scriptById(scriptId);
    if (script == null) {
      return const LxScriptTestResult(ok: false, ms: 0, text: '脚本不存在');
    }
    try {
      await LxRuntime.instance.ensureStarted();
      if (!script.ready) {
        if (script.error.isNotEmpty) {
          // 失败过的先复位重载（错误态会被解析链跳过）
          await LxRuntime.instance.unloadScript(scriptId);
        }
        await LxRuntime.instance
            .loadScript(scriptId)
            .timeout(const Duration(seconds: 15));
        await LxRuntime.instance.refreshStatus();
      }
      if (!script.ready) {
        final why = script.error.isEmpty
            ? (script.lastLog.isEmpty ? '初始化超时' : script.lastLog)
            : script.error;
        _record(scriptId, false, stopwatch.elapsedMilliseconds, '未就绪：$why');
        return LxScriptTestResult(
          ok: false,
          ms: stopwatch.elapsedMilliseconds,
          text: '未就绪：$why',
        );
      }
      // 平台优先当前曲库平台（同一脚本对不同平台的服务器通道不同）
      final preferred = _preferredPlatform();
      final platforms = [
        for (final p in LxRuntime.searchSupportedPlatforms)
          if (script.sources.containsKey(p)) p,
      ]..sort((a, b) {
          return (a == preferred ? 0 : 1).compareTo(b == preferred ? 0 : 1);
        });
      if (platforms.isEmpty) {
        _record(scriptId, false, stopwatch.elapsedMilliseconds,
            '未声明任何可用平台/音质');
        return LxScriptTestResult(
          ok: false,
          ms: stopwatch.elapsedMilliseconds,
          text: '初始化成功但未声明任何可用平台/音质',
        );
      }
      // 搜索测试曲（免签，不依赖脚本）
      String? songmid;
      String? usedPlatform;
      for (final platform in platforms) {
        try {
          final results = await Api.searchPlatform(platform, '周杰伦 晴天')
              .timeout(const Duration(seconds: 10));
          for (final item in results) {
            final value = item['songmid']?.toString() ?? '';
            if (value.isNotEmpty) {
              songmid = value;
              usedPlatform = platform;
              break;
            }
          }
        } catch (_) {}
        if (songmid != null) break;
      }
      if (songmid == null) {
        _record(scriptId, false, stopwatch.elapsedMilliseconds, '搜索链路异常');
        return LxScriptTestResult(
          ok: false,
          ms: stopwatch.elapsedMilliseconds,
          text: '平台搜索无结果（搜索链路异常，与脚本无关）',
        );
      }
      final qualitys = script.sources[usedPlatform!]!;
      final quality =
          qualitys.contains('128k') ? '128k' : qualitys.first;
      final raw = await LxRuntime.instance.musicUrlRaw(
        scriptId,
        usedPlatform,
        songmid,
        quality,
        name: '晴天',
        singer: '周杰伦',
      ).timeout(const Duration(seconds: 8));
      final url = raw['result']?.toString() ?? '';
      final okUrl = raw['ok'] == true && url.startsWith('http');
      if (!okUrl) {
        _record(scriptId, false, stopwatch.elapsedMilliseconds, '出链失败');
        return LxScriptTestResult(
          ok: false,
          ms: stopwatch.elapsedMilliseconds,
          text: '出链失败（$usedPlatform $quality）：$url',
        );
      }
      // 端到端验证：直链必须真的可下载才算「可用」——出链成功但 CDN
      // 已死的脚本进了音源位会把点歌拖进换源循环。
      if (!await Api.probeMediaUrl(url)) {
        _record(scriptId, false, stopwatch.elapsedMilliseconds, '直链不可达');
        return LxScriptTestResult(
          ok: false,
          ms: stopwatch.elapsedMilliseconds,
          text: '直链不可达：${url.split('/').take(3).join('/')}…',
        );
      }
      final ms = stopwatch.elapsedMilliseconds;
      _record(scriptId, true, ms, '可用');
      return LxScriptTestResult(ok: true, ms: ms, text: '可用 $ms ms');
    } catch (error) {
      _record(scriptId, false, stopwatch.elapsedMilliseconds, '测试失败');
      return LxScriptTestResult(
        ok: false,
        ms: stopwatch.elapsedMilliseconds,
        text: '测试失败：$error',
      );
    }
  }

  static String? _preferredPlatformCache;

  /// 当前曲库平台（首读后缓存；同一会话内平台切换对测试口径影响极小）。
  static String _preferredPlatform() {
    return _preferredPlatformCache ??=
        store.activeSettings?.lxPlatform ?? 'kw';
  }

  static void _record(String scriptId, bool ok, int ms, String text) {
    speedStore.update(
      lxSpeedKey(scriptId),
      SpeedResult(ms: ms, text: ok ? '可用' : text, ok: ok),
    );
  }
}
