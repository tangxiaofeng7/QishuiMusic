import 'dart:async';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'core/api.dart';
import 'core/appearance.dart';
import 'core/liked.dart';
import 'core/logging.dart';
import 'core/player.dart';
import 'core/selftest.dart';
import 'core/source.dart';
import 'core/store.dart' as store;
import 'core/updater.dart';
import 'ui/app.dart';

late PlayerController player;
late store.Settings settings;
late Appearance appearance;
late LikedStore likedStore;

Future<void> main() async {
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await initLogging();
    FlutterError.onError = (details) {
      logError('flutter', details.exception, details.stack);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      logError('platform', error, stack);
      return true;
    };

    appLog('main: start');
    settings = await store.Settings.load();
    store.activeSettings = settings;
    appearance = await Appearance.load();
    likedStore = LikedStore();
    unawaited(likedStore.loadFromPrefs());
    appLog('main: settings loaded (hasCookie=${settings.hasCookie})');
    player = await AudioService.init(
      builder: PlayerController.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.soda.qishuimusic.playback',
        androidNotificationChannelName: '汽水播放',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
    appLog('main: audio service ready');
    // lx 模式且选定了脚本：启动即初始化当前音源脚本（对齐 lx-music
    // 启动时初始化当前音源——否则第一次点歌要现场等懒加载 15s）。
    if (settings.sourceMode == 'lx' && settings.lxScript.isNotEmpty) {
      sourceStore.warmActiveScript();
    }
    // 恢复上次播放会话（队列/当前曲/模式/进度；点播放才真正续播）
    unawaited(player.restoreSession());
    // 恢复播放速度
    if (settings.speed != 1.0) {
      unawaited(player.setSpeed(settings.speed)
          .then((_) => appLog('main: speed=${settings.speed}')));
    }
    // 启动即配置 Rust 会话（Cookie/签名器/缓存目录）——不阻塞首屏：
    // UI 立即渲染（页面先吃 SWR 缓存），业务请求经 Api.sessionReady 自动排队。
    // 注意 gate 内只能调直连 FFI（Api.configure 走 init 符号、不经 _call），
    // 不能调 Api.ping 之类的业务方法——_call 会 await 这个 gate，自等待死锁。
    final rustSessionReady = () async {
      try {
        final cacheDir = await store.Settings.resolveCacheDir();
        appLog('main: cacheDir=$cacheDir');
        await Api.configure(settings.toFfiConfig(cacheDir));
        appLog('main: rust session configured');
      } catch (error, stack) {
        // 会话初始化失败不再拦 runApp：页面按各自错误路径展示并可重试
        logError('main.initRust', error, stack);
      }
    }();
    Api.sessionReady = rustSessionReady;
    // 已登录：把汽水账号喜欢列表并进全局喜欢存储（并集，本地不删）。
    // 必须等 gate 完成（Api.likedSongs 内部会 await sessionReady，
    // 在 gate 里调会自死锁）。
    unawaited(rustSessionReady.then((_) {
      if (settings.hasCookie) return likedStore.refreshFromServer();
    }));
    // 冒烟自检（容器里存在 SODAM_SELFTEST 标记时才跑，跑完自动删标记）
    unawaited(maybeRunSelfTest(player, appearance));
    // 启动后台静默检查更新（结果进 Updater.pendingUpdate，设置页显示徽标）
    unawaited(Updater.backgroundCheck());
    runApp(const QishuiApp());
    appLog('main: runApp done');
  }, (error, stack) {
    logError('zone', error, stack);
  });
}
