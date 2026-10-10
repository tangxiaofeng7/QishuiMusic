/// 设置存储（shared_preferences）与会话配置。
///
/// 2026-10 改造：签名服务/远程签名页/设备指纹配置全部移除——
/// 网页签名由 App 内置签名页（signer_bridge.dart）提供，不再依赖任何外部服务。

library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'logging.dart';
import 'lx_catalog.dart';

/// 应用沙盒根目录（iOS 上 path_provider 插件在 SPM 构建中偶发缺席，
/// 用进程 TMPDIR 即容器 tmp 的父目录推导，无插件依赖）。
Future<String> appContainerRoot() async {
  if (!kIsWeb && Platform.isIOS) {
    final tmp = Directory.systemTemp; // <container>/tmp
    return tmp.parent.path;
  }
  if (!kIsWeb && Platform.isAndroid) {
    final cache = await getTemporaryDirectory();
    return cache.parent.path;
  }
  return Directory.current.path;
}

/// 用户自定义 lx 脚本目录（容器根不可写，必须落在 Documents 下）。
String lxUserScriptsDirPath(String containerRoot) =>
    '$containerRoot/Documents/lx_sources';

/// 全局活动设置实例（main 启动时赋值；供不便 import main.dart 的核心层
/// 模块读取当前设置，如播放器的封面下载代理）。
Settings? activeSettings;

/// 汽水账号音质档位（key → 设置文案），直接对标官方 App 五档：
/// 全景声 / 录音室 / 无损 / 极高 / 标准（另加自动）。
/// key 直接透传 Rust 侧 `set_quality_preference`，也是缓存文件名的一部分；
/// 全景声/录音室在 Rust 侧做档位族精确匹配，取不到时逐级回落。
const Map<String, String> qualityOptions = {
  '': '自动',
  'spatial': '全景声',
  'hires': '录音室',
  'lossless': '无损',
  'highest': '极高',
  'medium': '标准',
};

/// 其他音源（LX 脚本链）音质档位文案：key 即脚本 quality 参数
/// （128k/320k/flac/flac24bit，lx-music 生态约定）。实际可选项 =
/// 当前平台就绪脚本声明 qualitys 的并集（LxRuntime.availableQualities），
/// 不写死；'' = 自动（flac → 320k → 128k 逐级尝试）。
const Map<String, String> lxQualityLabels = {
  '128k': '标准 128k',
  '320k': '极高 320k',
  'flac': '无损 FLAC',
  'flac24bit': 'Hi-Res 24bit',
};

/// 把取流链路回传的原始音质串归一成展示档位名。
///
/// 原始串形态：Rust describe_quality 的「全景声 324k / 录音室 324k / 无损 907k /
/// 极高 320k / 较高 257k / 标准 128k / · 试听」，外部链的
/// 「外部·独家LX flac / 外部·酷我 128k」。
/// 全景声/录音室是独立档位（对标官方），必须先于码率归档判断。
String qualityTierOf(String raw) {
  if (raw.contains('试听')) return '试听';
  final lower = raw.toLowerCase();
  if (raw.contains('全景声') ||
      lower.contains('spatial') ||
      lower.contains('atmos') ||
      lower.contains('dolby')) {
    return '全景声';
  }
  if (raw.contains('录音室') || lower.contains('hires') || lower.contains('hi_res')) {
    return '录音室';
  }
  if (raw.contains('无损') || lower.contains('flac')) return '无损';
  final match = RegExp(r'(\d{2,4})\s*k', caseSensitive: false).firstMatch(raw);
  if (match != null) {
    final kbps = int.tryParse(match.group(1)!) ?? 0;
    if (kbps >= 192) return '极高';
    if (kbps >= 96) return '标准';
    return '较低';
  }
  if (raw.contains('极高') || raw.contains('较高')) return '极高';
  if (raw.contains('标准')) return '标准';
  if (raw.contains('较低') || raw.contains('低')) return '较低';
  return raw;
}

class Settings {
  /// sodam 完整音质链路：内置默认签名服务（与上游客户端一致，开箱即用）。
  /// 用户可在音源详情页改成自建服务；留空保存/读取时回落这组默认值。
  static const String defaultSignerUrl = 'http://222.186.10.201:8921/sign';

  /// 内置签名服务的访问令牌。
  static const String defaultSignerToken =
      '05f8089b8c5f60c63f2a6dcfe1028d28ee2725a504f3e59b';

  Settings({
    this.cookie = '',
    this.quality = '',
    this.lxQuality = '',
    this.themeMode = 'system',
    this.speed = 1.0,
    this.extEnabled = true,
    this.sourceMode = 'default',
    this.lxPlatform = 'kw',
    this.lxScript = '',
    this.signerUrl = defaultSignerUrl,
    this.signerToken = defaultSignerToken,
    this.deviceId = '',
    this.iid = '',
    this.lyricTranslation = true,
    List<String>? lxDisabledScripts,
    List<String>? lxHiddenScripts,
    List<String>? lxScriptNames,
  }) : lxDisabledScripts = lxDisabledScripts ?? [],
       lxHiddenScripts = lxHiddenScripts ?? [],
       lxScriptNames = lxScriptNames ?? [];

  String cookie;

  /// 汽水账号音质档位（qualityOptions 的 key；'' = 自动）。
  String quality;

  /// 其他音源（LX 脚本链）音质档位（lxQualityLabels 的 key；'' = 自动）。
  /// 与 [quality] 分开存：两套档位体系不同，切音源各自记住各自的偏好。
  String lxQuality;
  String themeMode;

  /// 播放速度（1.0 = 常速；跨会话保留）。
  double speed;

  /// 外部音源回落（lx-music 式内置源）：汽水侧只有试听时按标题+歌手
  /// 匹配酷我免费整曲。默认开。
  bool extEnabled;

  /// 播放音源：default = 汽水账号（默认，含音质限免：免费曲全档位）；
  /// lx = 其他音源（洛雪脚本优先）。历史值 sodam 读取时归并为 default。
  String sourceMode;

  /// 其他音源下的曲库平台（'kw' = 酷我 / 'wy' = 网易云）：
  /// LX 模式的首页/发现/搜索按此平台出内容，切换即时生效。
  String lxPlatform;

  /// lx 模式下的激活取流脚本 id（对齐 lx-music「音源即脚本」：
  /// 播放只用该脚本出链，它不可用时自动回退其余就绪脚本；'' = 未
  /// 选定（UI 已不提供聚合选项，仅旧数据防御，解析链聚合兜底）。
  String lxScript;

  /// 当前音源显示名（设置页与播放页音质面板共用一套文案）。
  /// lx 模式下音源 = 激活脚本，曲库平台随行展示。
  String get sourceName => switch (sourceMode) {
        'lx' => '其他音源 · ${lxPlatformName(lxPlatform)}',
        _ => '汽水账号',
      };

  /// 音质限免链路：签名服务地址（libmssdk 形态 POST /sign）。
  /// 缺省为 [defaultSignerUrl]（上游客户端同款内置服务），配置即生效
  /// （汽水账号音源内部挂载，免费曲可取全景声/录音室/无损）。
  String signerUrl;

  /// 签名服务鉴权令牌。缺省为 [defaultSignerToken]。
  String signerToken;

  /// 设备指纹（device_id）。与上游客户端一致不对用户展示：为空时由
  /// [ensureDeviceId] 自动生成稳定 16 位数字（签名服务的 mssdk 桥会取
  /// URL 里的 device_id 来 init bdms，App 端自造即可生效）。
  String deviceId;

  /// install id（可选，fp 缺省回落 device_id）。
  String iid;

  /// 歌词翻译显示（播放页「译」开关，有译文才生效）。
  bool lyricTranslation;

  /// 已停用的洛雪脚本 id（其余全部参与解析链）。
  List<String> lxDisabledScripts;

  /// 已隐藏的内置洛雪脚本 id（列表与解析链都不再出现；自定义脚本删除即消失）。
  List<String> lxHiddenScripts;

  /// 内置洛雪脚本的自定义名（扁平数组 [id, name, id, name, …]，让内置
  /// 脚本与自定义脚本一样支持改名；自定义脚本名称在自身注册表里）。
  List<String> lxScriptNames;

  Map<String, String> lxScriptNameMap() => {
    for (var i = 0; i + 1 < lxScriptNames.length; i += 2)
      lxScriptNames[i]: lxScriptNames[i + 1],
  };

  bool get hasCookie => cookie.trim().isNotEmpty;

  /// 确保有稳定的 device_id（16 位数字）：启动加载时调用，已有值
  /// （含旧版手填的抓包值）保持不变。仅改内存不落盘，随下一次
  /// save() 持久化。
  void ensureDeviceId() {
    if (deviceId.trim().length == 16) return;
    final random = Random.secure();
    final digits = List<String>.generate(
      15,
      (_) => random.nextInt(10).toString(),
    );
    deviceId = '${random.nextInt(9) + 1}${digits.join()}';
  }

  /// 存储值空/缺省时回落内置默认（老版本存过空串的安装同样吃到内置值）。
  static String _signerOr(String? stored, String fallback) =>
      (stored == null || stored.trim().isEmpty) ? fallback : stored;

  static Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = Settings(
      cookie: prefs.getString('cookie') ?? '',
      quality: prefs.getString('quality') ?? '',
      lxQuality: prefs.getString('lxQuality') ?? '',
      themeMode: prefs.getString('themeMode') ?? 'system',
      speed: prefs.getDouble('speed') ?? 1.0,
      extEnabled: prefs.getBool('extEnabled') ?? true,
      sourceMode: prefs.getString('sourceMode') ?? 'default',
      // 历史版本只认 kw/wy；现在四平台都支持，未知值回落 kw
      lxPlatform: switch (prefs.getString('lxPlatform')) {
        'wy' => 'wy',
        'kg' => 'kg',
        'tx' => 'tx',
        _ => 'kw',
      },
      lxScript: prefs.getString('lxScript') ?? '',
      signerUrl: _signerOr(prefs.getString('signerUrl'), defaultSignerUrl),
      signerToken: _signerOr(
        prefs.getString('signerToken'),
        defaultSignerToken,
      ),
      deviceId: prefs.getString('deviceId') ?? '',
      iid: prefs.getString('iid') ?? '',
      lyricTranslation: prefs.getBool('lyricTranslation') ?? true,
      lxDisabledScripts: prefs.getStringList('lxDisabledScripts') ?? [],
      lxHiddenScripts: prefs.getStringList('lxHiddenScripts') ?? [],
      lxScriptNames: prefs.getStringList('lxScriptNames') ?? [],
    );
    // 历史值 sodam（独立音源已移除，签名链路并入汽水账号）→ default。
    if (settings.sourceMode == 'sodam') settings.sourceMode = 'default';
    // 音质限免需要稳定设备指纹：加载即保证（幂等，已有 16 位值不动）。
    settings.ensureDeviceId();
    return settings;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cookie', cookie);
    await prefs.setString('quality', quality);
    await prefs.setString('lxQuality', lxQuality);
    await prefs.setString('themeMode', themeMode);
    await prefs.setDouble('speed', speed);
    await prefs.setBool('extEnabled', extEnabled);
    await prefs.setString('sourceMode', sourceMode);
    await prefs.setString('lxPlatform', lxPlatform);
    await prefs.setString('lxScript', lxScript);
    await prefs.setString('signerUrl', signerUrl);
    await prefs.setString('signerToken', signerToken);
    await prefs.setString('deviceId', deviceId);
    await prefs.setString('iid', iid);
    await prefs.setBool('lyricTranslation', lyricTranslation);
    await prefs.setStringList('lxDisabledScripts', lxDisabledScripts);
    await prefs.setStringList('lxHiddenScripts', lxHiddenScripts);
    await prefs.setStringList('lxScriptNames', lxScriptNames);
    // 清掉历史版本遗留的 fp 键（现在 fp 由 deviceId 推导），
    // 以及已下线的 HTTP 代理键。
    await prefs.remove('fp');
    await prefs.remove('browserSignerUrl');
    await prefs.remove('browserSignerToken');
    await prefs.remove('proxyUrl');
  }

  /// Rust 侧需要的缓存目录（应用沙盒内）。
  ///
  /// 2026-10 迁移：iOS 落点从 `tmp/sodam` 改为 `Library/Caches/sodam`，
  /// Android 同步改到数据根下的 `cache/sodam`——tmp 一不被系统储存
  /// 管理/外部清理工具识别为缓存（设置页显示几百 M、工具却说"没有
  /// 缓存"），二会被 iOS 在储存紧张时静默清空（缓存曲目无声消失）；
  /// 标准缓存目录才是「可被清理」的正确落点。旧目录内容在首次访问
  /// 时自动搬移（[migrateLegacyCache]，一次性）。越狱系统级安装
  /// （/var/jb，无数据容器）写不进 Library/Caches 时回落 tmp。
  static Future<void>? _cacheMigration;

  static Future<String> resolveCacheDir() async {
    final root = await appContainerRoot();
    String? preferred;
    if (!kIsWeb && Platform.isIOS) {
      preferred = '$root/Library/Caches/sodam';
    } else if (!kIsWeb && Platform.isAndroid) {
      preferred = '$root/cache/sodam';
    }
    var dir = Directory(preferred ?? '$root/tmp/sodam');
    if (preferred != null) {
      // Library/Caches 在无数据容器的安装形态下可能不可写：写探针验证，
      // 失败回落 tmp（旧落点，任何形态都可写）。
      try {
        dir.createSync(recursive: true);
        final probe = File('${dir.path}/.writable');
        probe.writeAsStringSync('');
        probe.deleteSync();
      } catch (_) {
        appLog('store: 标准缓存目录不可写，回落 tmp（无数据容器形态）');
        dir = Directory('$root/tmp/sodam');
      }
    }
    if (!dir.existsSync()) dir.createSync(recursive: true);
    await (_cacheMigration ??= migrateLegacyCache(root, dir.path));
    return dir.path;
  }

  /// 一次性迁移：旧缓存目录（`tmp/sodam`）下的音频/封面/页面缓存整套
  /// rename 进新目录（同容器原子移动，秒完），再把索引 index.json 里
  /// 记录的绝对路径改写到新目录。失败容忍——最坏丢一次缓存重新下载
  /// （索引 list() 自愈剔除失效条目），不阻塞启动。
  @visibleForTesting
  static Future<void> migrateLegacyCache(String root, String newDir) async {
    try {
      final legacy = Directory('$root/tmp/sodam');
      if (!legacy.existsSync() || legacy.path == newDir) return;
      for (final item in legacy.listSync()) {
        final dest = '$newDir/${item.path.split('/').last}';
        // 新目录已有同名（曾迁移后降级又升级的边缘场景）：保留新目录
        // 内容，旧文件随 tmp 由系统清理，不互相覆盖。
        if (File(dest).existsSync() || Directory(dest).existsSync()) continue;
        item.renameSync(dest);
      }
      rewriteCacheIndexPaths(newDir);
      // 只在搬空后清理旧壳；残留的空目录结构留给系统 tmp 清理。
      if (legacy.listSync().isEmpty) legacy.deleteSync();
      appLog('store: 旧缓存已迁移到 $newDir');
    } catch (error) {
      appLog('store: 旧缓存迁移失败(忽略，重新缓存即可): $error');
    }
  }

  /// index.json 的 path 字段是落盘时的绝对路径，目录迁移后按文件名
  /// 重拼到当前 tracks 目录（顺带容忍手动挪动过的杂散路径）。
  @visibleForTesting
  static void rewriteCacheIndexPaths(String cacheDir) {
    final file = File('$cacheDir/tracks/index.json');
    if (!file.existsSync()) return;
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! List) return;
      final tracksDir = '$cacheDir/tracks';
      var changed = false;
      final entries = raw.whereType<Map>().map((item) {
        final map = Map<String, dynamic>.from(item);
        final path = map['path']?.toString() ?? '';
        if (path.isNotEmpty && !path.startsWith(tracksDir)) {
          map['path'] = '$tracksDir/${path.split('/').last}';
          changed = true;
        }
        return map;
      }).toList();
      if (changed) file.writeAsStringSync(jsonEncode(entries));
    } catch (error) {
      appLog('store: 缓存索引路径改写失败(忽略): $error');
    }
  }

  Map<String, dynamic> toFfiConfig(String cacheDir) => {
    'cookie': cookie,
    'quality': quality,
    'cacheDir': cacheDir,
    'extEnabled': extEnabled,
    'sourceMode': sourceMode,
    'signerUrl': signerUrl,
    'signerToken': signerToken,
    'deviceId': deviceId,
    'iid': iid,
  };
}
