/// 外观与个性化（DIY 美化）设置：主题色板 / 歌词样式 / 进度条样式 /
/// 播放页壁纸 / 播放页快捷动作排序。
///
/// 单例 ChangeNotifier（main 启动时加载，全局 `appearance` 见 main.dart）：
/// 改动即 notifyListeners 全局生效，SharedPreferences 持久化；
/// 另支持 JSON 备份导出 / 导入（设置页「备份与恢复」）。

library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'logging.dart';
import 'store.dart' as store;

/// 进度条样式：classic = Material 滑条（默认，保持原有观感），
/// 其余 4 款为播放页自绘样式（借鉴 Beans-Music）。
enum ProgressBarStyle { classic, streamer, glow, aurora, wave }

extension ProgressBarStyleLabel on ProgressBarStyle {
  String get label => switch (this) {
        ProgressBarStyle.classic => '经典',
        ProgressBarStyle.streamer => '流光',
        ProgressBarStyle.glow => '辉光',
        ProgressBarStyle.aurora => '极光',
        ProgressBarStyle.wave => '波浪',
      };

  String get storage => switch (this) {
        ProgressBarStyle.classic => 'classic',
        ProgressBarStyle.streamer => 'streamer',
        ProgressBarStyle.glow => 'glow',
        ProgressBarStyle.aurora => 'aurora',
        ProgressBarStyle.wave => 'wave',
      };

  static ProgressBarStyle fromStorage(String? value) =>
      ProgressBarStyle.values
          .where((style) => style.storage == value)
          .firstOrNull ??
      ProgressBarStyle.classic;
}

/// 旧版内置渐变壁纸（v0.2.0 起设置页改为选色器，此表仅用于
/// 已保存 `gradient:<id>` 配置的兼容渲染与自测）。
class WallpaperPreset {
  const WallpaperPreset(this.id, this.name, this.colors);
  final String id;
  final String name;
  final List<Color> colors;
}

const List<WallpaperPreset> wallpaperPresets = [
  WallpaperPreset('dusk', '暮紫', [
    Color(0xFF241B47),
    Color(0xFF53357A),
    Color(0xFF8E5AA0),
  ]),
  WallpaperPreset('midnight', '午夜', [
    Color(0xFF0F2027),
    Color(0xFF203A43),
    Color(0xFF2C5364),
  ]),
  WallpaperPreset('ocean', '深海', [
    Color(0xFF0B2545),
    Color(0xFF1B4370),
    Color(0xFF2E6291),
  ]),
  WallpaperPreset('forest', '森林', [
    Color(0xFF0E2A1D),
    Color(0xFF1F5B3F),
    Color(0xFF3B7D5A),
  ]),
  WallpaperPreset('sakura', '夜樱', [
    Color(0xFF3A1F2E),
    Color(0xFF6E3B57),
    Color(0xFFA55E7A),
  ]),
  WallpaperPreset('ember', '暖炭', [
    Color(0xFF231512),
    Color(0xFF4E2A1B),
    Color(0xFF7A4326),
  ]),
];

/// 自选壁纸色 → 三段沉浸式渐变：保留色相与饱和度、把明度压到
/// 30% / 52% / 70%（与旧内置预设同构，保证白色文字可读）。
List<Color> customWallpaperGradient(int argb) {
  final base = HSVColor.fromColor(Color(argb));
  return [
    base.withValue(0.30).toColor(),
    base.withValue(0.52).toColor(),
    base.withValue(0.70).toColor(),
  ];
}

/// 预设主题色板（设置 → 个性化外观；关闭「跟随封面」时生效）。
const List<(Color, String)> accentPresets = [
  (Color(0xFF3AAFA9), '汽水青'),
  (Color(0xFF3D7BE8), '晴空蓝'),
  (Color(0xFF7C5CE0), '星夜紫'),
  (Color(0xFFC257E8), '兰花紫'),
  (Color(0xFFE8547C), '樱花粉'),
  (Color(0xFFF0704A), '落日橙'),
  (Color(0xFFE8B93B), '柠檬黄'),
  (Color(0xFF57B86B), '苔藓绿'),
  (Color(0xFF2E9E8F), '松石绿'),
  (Color(0xFF6B7B8C), '石墨灰'),
];

/// 播放页快捷动作 id（长按拖动排序）：queue 播放队列 / speed 倍速 /
/// sleep 睡眠定时 / translate 歌词翻译 / share 分享 / lyrics 歌词样式。
const List<String> defaultPlayerActions = [
  'queue',
  'speed',
  'sleep',
  'translate',
  'share',
  'lyrics',
];

/// 相册壁纸落盘位置（Documents 下，用户可见可备份）。
Future<File> wallpaperFile() async {
  final root = await store.appContainerRoot();
  return File('$root/Documents/wallpaper.img');
}

class Appearance extends ChangeNotifier {
  Appearance._();

  static Future<Appearance> load() async {
    final prefs = await SharedPreferences.getInstance();
    return Appearance._()
      .._accentFollowCover = prefs.getBool('app.accentFollowCover') ?? true
      .._accentColor = prefs.getInt('app.accentColor') ?? 0xFF3AAFA9
      .._lyricFontSize = prefs.getDouble('app.lyricFontSize') ?? 17
      .._lyricLineSpacing = prefs.getDouble('app.lyricLineSpacing') ?? 1.0
      .._lyricCustomColors = prefs.getBool('app.lyricCustomColors') ?? false
      .._lyricBaseColor = prefs.getInt('app.lyricBaseColor') ?? 0xFF9E9E9E
      .._lyricHighlightColor =
          prefs.getInt('app.lyricHighlightColor') ?? 0xFF3AAFA9
      .._lyricGlow = prefs.getBool('app.lyricGlow') ?? false
      .._lyricTilt = prefs.getBool('app.lyricTilt') ?? false
      .._progressBar =
          ProgressBarStyleLabel.fromStorage(prefs.getString('app.progressBar'))
      .._wallpaper = prefs.getString('app.wallpaper') ?? 'auto'
      .._wallpaperBlur = prefs.getDouble('app.wallpaperBlur') ?? 14
      .._wallpaperColor = prefs.getInt('app.wallpaperColor') ?? 0xFF53357A
      .._playerActions =
          prefs.getStringList('app.playerActions') ?? defaultPlayerActions;
  }

  // ---- 主题 ----

  bool _accentFollowCover = true;

  /// 全局主题色跟随当前曲目封面主色（无曲目 / 取色失败回落品牌色）。
  bool get accentFollowCover => _accentFollowCover;

  int _accentColor = 0xFF3AAFA9;

  /// 预设色板选中的主题色（不跟随封面时生效）。
  Color get accentColor => Color(_accentColor);

  /// 当前曲目封面主色（播放页取色后回写；null = 未取到）。
  Color? dominantColor;

  /// 播放页取色回写：值变化才通知（全局主题「跟随封面」由此驱动）。
  void updateDominant(Color? color) {
    final old = dominantColor;
    dominantColor = color;
    if (old?.toARGB32() != color?.toARGB32()) notifyListeners();
  }

  /// 生效主题色：跟随封面 → 封面主色 / 品牌色；否则预设色。
  Color get effectiveAccent =>
      _accentFollowCover ? (dominantColor ?? accentColor) : accentColor;

  // ---- 歌词 DIY ----

  double _lyricFontSize = 17;
  double _lyricLineSpacing = 1.0;
  bool _lyricCustomColors = false;
  int _lyricBaseColor = 0xFF9E9E9E;
  int _lyricHighlightColor = 0xFF3AAFA9;
  bool _lyricGlow = false;
  bool _lyricTilt = false;

  /// 当前行字号（非当前行 -2，译文 -5）。
  double get lyricFontSize => _lyricFontSize;

  /// 行距倍数（0.6 ~ 2.0）。
  double get lyricLineSpacing => _lyricLineSpacing;

  /// 自定义歌词配色（关闭 = 跟随播放页主题）。
  bool get lyricCustomColors => _lyricCustomColors;
  Color get lyricBaseColor => Color(_lyricBaseColor);
  Color get lyricHighlightColor => Color(_lyricHighlightColor);

  /// 当前行发光。
  bool get lyricGlow => _lyricGlow;

  /// 当前行 3D 透视倾斜。
  bool get lyricTilt => _lyricTilt;

  // ---- 进度条 / 封面形态 ----

  ProgressBarStyle _progressBar = ProgressBarStyle.classic;
  ProgressBarStyle get progressBar => _progressBar;

  // ---- 壁纸 ----

  /// `'auto'` = 封面取色渐变（默认）；`'custom'` = 自选色渐变；
  /// `'gradient:<id>'` = 旧版内置渐变（兼容已存配置）；`'photo'` = 相册图片。
  String _wallpaper = 'auto';
  String get wallpaper => _wallpaper;

  bool get wallpaperIsPhoto => _wallpaper == 'photo';
  bool get wallpaperIsCustom => _wallpaper == 'custom';

  WallpaperPreset? get wallpaperPreset {
    if (!_wallpaper.startsWith('gradient:')) return null;
    final id = _wallpaper.substring('gradient:'.length);
    return wallpaperPresets
        .where((preset) => preset.id == id)
        .firstOrNull;
  }

  int _wallpaperColor = 0xFF53357A;

  /// 选色器当前壁纸色（选过就一直保留，重开选色器以此为初值）。
  Color get wallpaperColor => Color(_wallpaperColor);

  /// 自选色模式生效时的派生渐变（其余模式返回 null）。
  List<Color>? get wallpaperCustomColors =>
      wallpaperIsCustom ? customWallpaperGradient(_wallpaperColor) : null;

  double _wallpaperBlur = 14;

  /// 相册壁纸模糊度（sigma 0 ~ 30）。
  double get wallpaperBlur => _wallpaperBlur;

  // ---- 播放页快捷动作排序 ----

  List<String> _playerActions = defaultPlayerActions;
  List<String> get playerActions => List.unmodifiable(_playerActions);

  // ---- 更新入口 ----

  void setAccent({required bool followCover, int? color}) {
    _accentFollowCover = followCover;
    if (color != null) _accentColor = color;
    _save();
    notifyListeners();
  }

  void updateLyrics({
    double? fontSize,
    double? lineSpacing,
    bool? customColors,
    int? baseColor,
    int? highlightColor,
    bool? glow,
    bool? tilt,
  }) {
    if (fontSize != null) {
      _lyricFontSize = fontSize.clamp(12.0, 32.0);
    }
    if (lineSpacing != null) {
      _lyricLineSpacing = lineSpacing.clamp(0.6, 2.0);
    }
    if (customColors != null) _lyricCustomColors = customColors;
    if (baseColor != null) _lyricBaseColor = baseColor;
    if (highlightColor != null) _lyricHighlightColor = highlightColor;
    if (glow != null) _lyricGlow = glow;
    if (tilt != null) _lyricTilt = tilt;
    _save();
    notifyListeners();
  }

  void resetLyrics() {
    _lyricFontSize = 17;
    _lyricLineSpacing = 1.0;
    _lyricCustomColors = false;
    _lyricGlow = false;
    _lyricTilt = false;
    _save();
    notifyListeners();
  }

  void setProgressBar(ProgressBarStyle style) {
    _progressBar = style;
    _save();
    notifyListeners();
  }

  void setWallpaper(String value, {double? blur}) {
    _wallpaper = value;
    if (blur != null) _wallpaperBlur = blur.clamp(0.0, 30.0);
    _save();
    notifyListeners();
  }

  /// 选色器确认：写入自选色并切到 custom 模式。
  void setWallpaperColor(int argb) {
    _wallpaperColor = argb;
    _wallpaper = 'custom';
    _save();
    notifyListeners();
  }

  void setWallpaperBlur(double blur) {
    _wallpaperBlur = blur.clamp(0.0, 30.0);
    _save();
    notifyListeners();
  }

  /// 播放页快捷动作重排（ReorderableListView.onReorderItem 语义：
  /// newIndex 已由框架校正为移除旧位后的插入下标）。
  void reorderPlayerActions(int oldIndex, int newIndex) {
    final actions = _playerActions.toList();
    if (oldIndex < 0 || oldIndex >= actions.length) return;
    final id = actions.removeAt(oldIndex);
    actions.insert(newIndex.clamp(0, actions.length), id);
    _playerActions = actions;
    _save();
    notifyListeners();
  }

  void resetPlayerActions() {
    _playerActions = defaultPlayerActions.toList();
    _save();
    notifyListeners();
  }

  void _save() {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('app.accentFollowCover', _accentFollowCover);
      prefs.setInt('app.accentColor', _accentColor);
      prefs.setDouble('app.lyricFontSize', _lyricFontSize);
      prefs.setDouble('app.lyricLineSpacing', _lyricLineSpacing);
      prefs.setBool('app.lyricCustomColors', _lyricCustomColors);
      prefs.setInt('app.lyricBaseColor', _lyricBaseColor);
      prefs.setInt('app.lyricHighlightColor', _lyricHighlightColor);
      prefs.setBool('app.lyricGlow', _lyricGlow);
      prefs.setBool('app.lyricTilt', _lyricTilt);
      prefs.setString('app.progressBar', _progressBar.storage);
      prefs.setString('app.wallpaper', _wallpaper);
      prefs.setDouble('app.wallpaperBlur', _wallpaperBlur);
      prefs.setInt('app.wallpaperColor', _wallpaperColor);
      prefs.setStringList('app.playerActions', _playerActions);
    }).catchError((Object error) {
      appLog('appearance: 持久化失败(忽略): $error');
    });
  }

  // ---- 备份导出 / 导入 ----

  Map<String, dynamic> toBackupMap() => {
        'accentFollowCover': _accentFollowCover,
        'accentColor': _accentColor,
        'lyricFontSize': _lyricFontSize,
        'lyricLineSpacing': _lyricLineSpacing,
        'lyricCustomColors': _lyricCustomColors,
        'lyricBaseColor': _lyricBaseColor,
        'lyricHighlightColor': _lyricHighlightColor,
        'lyricGlow': _lyricGlow,
        'lyricTilt': _lyricTilt,
        'progressBar': _progressBar.storage,
        'wallpaper': _wallpaper == 'photo' ? 'auto' : _wallpaper,
        'wallpaperBlur': _wallpaperBlur,
        'wallpaperColor': _wallpaperColor,
        'playerActions': _playerActions,
      };

  /// 从备份恢复（未知字段忽略；壁纸为相册图时回落 auto——图片不随 JSON 搬）。
  void applyBackupMap(Map<String, dynamic> map) {
    if (map['accentFollowCover'] is bool) {
      _accentFollowCover = map['accentFollowCover'] as bool;
    }
    final accent = _asInt(map['accentColor']);
    if (accent != null) _accentColor = accent;
    final size = _asDouble(map['lyricFontSize']);
    if (size != null) _lyricFontSize = size.clamp(12.0, 32.0);
    final spacing = _asDouble(map['lyricLineSpacing']);
    if (spacing != null) _lyricLineSpacing = spacing.clamp(0.6, 2.0);
    if (map['lyricCustomColors'] is bool) {
      _lyricCustomColors = map['lyricCustomColors'] as bool;
    }
    final base = _asInt(map['lyricBaseColor']);
    if (base != null) _lyricBaseColor = base;
    final highlight = _asInt(map['lyricHighlightColor']);
    if (highlight != null) _lyricHighlightColor = highlight;
    if (map['lyricGlow'] is bool) _lyricGlow = map['lyricGlow'] as bool;
    if (map['lyricTilt'] is bool) _lyricTilt = map['lyricTilt'] as bool;
    final bar = map['progressBar']?.toString();
    if (bar != null) {
      _progressBar = ProgressBarStyleLabel.fromStorage(bar);
    }
    final wallpaper = map['wallpaper']?.toString();
    if (wallpaper != null && wallpaper != 'photo') _wallpaper = wallpaper;
    final blur = _asDouble(map['wallpaperBlur']);
    if (blur != null) _wallpaperBlur = blur.clamp(0.0, 30.0);
    final wallpaperColor = _asInt(map['wallpaperColor']);
    if (wallpaperColor != null) _wallpaperColor = wallpaperColor;
    final actions = map['playerActions'];
    if (actions is List) {
      final known = actions
          .map((item) => item.toString())
          .where(defaultPlayerActions.contains)
          .toList();
      if (known.isNotEmpty) _playerActions = known;
    }
    _save();
    notifyListeners();
  }

  static int? _asInt(Object? value) =>
      value is int ? value : (value is num ? value.toInt() : null);

  static double? _asDouble(Object? value) =>
      value is double ? value : (value is num ? value.toDouble() : null);
}
