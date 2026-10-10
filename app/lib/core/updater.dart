/// 在线升级：GitHub Releases 检查新版本，经 TrollStore scheme 拉起安装。
///
/// 安装通道（与部署脚本同一路径）：TrollStore/TrollStoreLite 注册的
/// `apple-magnifier://install?url=<ipa>` 能直接装无签名 ipa（内部伪签），
/// 用户在弹窗点一次「安装」即可；未装 TrollStore 时回落到浏览器打开
/// Release 页面手动下载。

library;

import 'dart:convert';
import 'dart:io';

import '../brand.dart';
import 'logging.dart';
import 'platform.dart';

/// 一次成功检查拿到的 Release 信息。
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.notes,
    this.ipaUrl,
    required this.htmlUrl,
  });

  /// tag 去掉 v 前缀后的版本号（1.0.0）。
  final String version;
  final String notes;
  final String? ipaUrl;
  final String htmlUrl;
}

/// 检查结果。
enum UpdateCheck { latest, available, error }

class UpdateCheckResult {
  const UpdateCheckResult(this.status, {this.release, this.error});

  final UpdateCheck status;
  final ReleaseInfo? release;
  final String? error;
}

/// 朴素 semver 比较：按点分段逐位比数字，非数字段按字符串。
/// 返回正数 = a 更新，0 = 相同，负数 = b 更新。
int compareVersions(String a, String b) {
  int cmp(List<String> x, List<String> y) {
    final n = x.length > y.length ? x.length : y.length;
    for (var i = 0; i < n; i++) {
      final sx = i < x.length ? x[i] : '';
      final sy = i < y.length ? y[i] : '';
      final nx = int.tryParse(sx);
      final ny = int.tryParse(sy);
      int c;
      if (nx != null && ny != null) {
        c = nx.compareTo(ny);
      } else {
        c = sx.compareTo(sy);
      }
      if (c != 0) return c;
    }
    return 0;
  }

  return cmp(a.split('.'), b.split('.'));
}

class Updater {
  Updater._();

  static const _apiLatest =
      'https://api.github.com/repos/tangxiaofeng7/qishuimusic/releases/latest';
  static const _trollStoreScheme = 'apple-magnifier://';

  /// 后台静默检查的结果（启动时查一次，设置页入口显示徽标）。
  static ReleaseInfo? pendingUpdate;

  static HttpClient _client() {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);
    return client;
  }

  /// 检查 GitHub 最新 Release。当前为 dev 构建（未注入版本号）时
  /// 一律提示可更新（无法比较）。
  static Future<UpdateCheckResult> check() async {
    try {
      final client = _client();
      try {
        final request = await client
            .getUrl(Uri.parse(_apiLatest))
            .timeout(const Duration(seconds: 12));
        request.headers.set(HttpHeaders.acceptHeader,
            'application/vnd.github+json');
        request.headers.set(HttpHeaders.userAgentHeader, 'SodaM-App');
        final response = await request.close().timeout(
              const Duration(seconds: 15),
            );
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          return UpdateCheckResult(UpdateCheck.error,
              error: 'GitHub API HTTP ${response.statusCode}');
        }
        final data = jsonDecode(body);
        if (data is! Map) {
          return const UpdateCheckResult(UpdateCheck.error,
              error: '回包格式异常');
        }
        final tag = data['tag_name']?.toString() ?? '';
        if (tag.isEmpty) {
          return const UpdateCheckResult(UpdateCheck.error,
              error: 'Release 缺少 tag');
        }
        final version = tag.replaceFirst(RegExp('^v'), '');
        String? ipaUrl;
        final assets = data['assets'];
        if (assets is List) {
          for (final asset in assets) {
            if (asset is Map) {
              final name = asset['name']?.toString() ?? '';
              if (name.toLowerCase().endsWith('.ipa')) {
                ipaUrl = asset['browser_download_url']?.toString();
                break;
              }
            }
          }
        }
        final release = ReleaseInfo(
          version: version,
          notes: data['body']?.toString() ?? '',
          ipaUrl: ipaUrl,
          htmlUrl: data['html_url']?.toString() ?? '',
        );
        final current = kAppVersion == 'dev' ? '0.0.0' : kAppVersion;
        if (compareVersions(release.version, current) > 0) {
          pendingUpdate = release;
          return UpdateCheckResult(UpdateCheck.available, release: release);
        }
        return UpdateCheckResult(UpdateCheck.latest, release: release);
      } finally {
        client.close(force: true);
      }
    } catch (error) {
      return UpdateCheckResult(UpdateCheck.error, error: '$error');
    }
  }

  /// 启动后台静默检查（只更新 pendingUpdate，不弹任何 UI）。
  static Future<void> backgroundCheck() async {
    final result = await check();
    if (result.status == UpdateCheck.available) {
      appLog('update: 新版本 ${result.release!.version} 可用');
    } else if (result.status == UpdateCheck.error) {
      appLog('update: 检查失败 ${result.error}');
    }
  }

  /// 是否装了 TrollStore（能否用 install-url 通道）。
  static Future<bool> hasTrollStore() =>
      canOpenUrl(_trollStoreScheme);

  /// 拉起安装：优先 TrollStore install-url（直传远程 ipa，由 TrollStore
  /// 下载安装）；否则打开 Release 页面让用户自行下载。
  /// 返回给 UI 的提示文案。
  static Future<String> startInstall(ReleaseInfo release) async {
    final ipa = release.ipaUrl;
    if (ipa != null && await hasTrollStore()) {
      final ok = await openUrl(
        '$_trollStoreScheme'
        'install?url=${Uri.encodeComponent(ipa)}',
      );
      if (ok) {
        return '已交给 TrollStore 下载安装，请在弹窗中确认（安装完成后'
            '如遇无法上网，到系统设置里允许本 App 的网络权限）';
      }
    }
    final ok = await openUrl(release.htmlUrl);
    return ok
        ? '未检测到 TrollStore，已打开发布页——请手动下载 ipa 安装'
        : '无法打开安装通道，请用浏览器访问：\n${release.htmlUrl}';
  }
}
