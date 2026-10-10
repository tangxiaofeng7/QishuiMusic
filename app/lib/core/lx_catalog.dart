/// 其他音源（LX 模式）的曲库内容词库。
///
/// LX 脚本本质是「songmid → 播放地址」的转换器，不提供曲库；曲库由
/// App 的免签平台接口承担（榜单 + 搜索）。首页/发现页的榜单卡来自
/// 各平台的**免签真实榜单**（kg/wy/tx）或关键词搜索流（kw），随音源
/// 换装——切换音源即切换整套榜单目录，不依赖汽水任何接口。

library;

/// 榜单卡（id = 平台榜单 id；title 显示名；emoji 装饰）。
typedef LxChart = ({String id, String title, String emoji});

/// 首页场景卡（关键词即内容源，点卡切换重拉）。
/// 酷我官方榜单接口需签名（2026-10 实测），无免签榜单——关键词搜索流
/// 即酷我的「榜单」形态，id = 搜索关键词。
const List<LxChart> lxScenes = [
  (id: '热门', title: '热门', emoji: '🔥'),
  (id: '新歌', title: '新歌', emoji: '🆕'),
  (id: '抖音热歌', title: '抖音热歌', emoji: '🎵'),
  (id: '经典老歌', title: '经典老歌', emoji: '📻'),
  (id: '影视金曲', title: '影视金曲', emoji: '🎬'),
  (id: '伤感', title: '伤感', emoji: '🌧️'),
  (id: '民谣', title: '民谣', emoji: '🎸'),
  (id: '轻音乐', title: '轻音乐', emoji: '🌙'),
  (id: '粤语', title: '粤语', emoji: '🏙️'),
  (id: '电音', title: '电音', emoji: '⚡'),
];

/// 各平台免签真榜单（id 均为 2026-10-10 实测可用；榜单曲目实时拉取）：
/// * kg：rankid（mobilecdn v3 rank 接口）
/// * wy：官方榜单歌单 id（music.163.com playlist detail）
/// * tx：topid（fcg_v8_toplist_cp 接口）
const List<LxChart> _kgCharts = [
  (id: '8888', title: 'TOP500', emoji: '🔥'),
  (id: '6666', title: '飙升榜', emoji: '🚀'),
  (id: '52144', title: '短视频热歌榜', emoji: '🎵'),
  (id: '82831', title: '网络热歌榜', emoji: '📻'),
  (id: '24971', title: 'DJ热歌榜', emoji: '⚡'),
  (id: '51341', title: '民谣榜', emoji: '🎸'),
  (id: '59900', title: '纯音乐榜', emoji: '🌙'),
  (id: '33160', title: '电音榜', emoji: '🎧'),
];

const List<LxChart> _wyCharts = [
  (id: '3778678', title: '热歌榜', emoji: '🔥'),
  (id: '3779629', title: '新歌榜', emoji: '🆕'),
  (id: '19723756', title: '飙升榜', emoji: '🚀'),
  (id: '2884035', title: '原创榜', emoji: '✍️'),
];

const List<LxChart> _txCharts = [
  (id: '26', title: '巅峰榜·热歌', emoji: '🔥'),
  (id: '27', title: '巅峰榜·新歌', emoji: '🆕'),
  (id: '62', title: '飙升榜', emoji: '🚀'),
  (id: '4', title: '巅峰榜·流行指数', emoji: '💥'),
];

/// 音源榜单目录：切音源即换整套目录（首页顶部卡条随音源动态变动）。
/// 未知平台回落酷我关键词流，保证任何音源都有内容形态。
List<LxChart> lxCatalogFor(String platform) => switch (platform) {
      'kg' => _kgCharts,
      'wy' => _wyCharts,
      'tx' => _txCharts,
      _ => lxScenes, // kw 及未知平台：关键词搜索流
    };

/// 搜索页空态热词（平台无关，点击即按当前平台搜索）。
const List<String> lxHotWords = [
  '周杰伦',
  '热门歌曲',
  '抖音热歌',
  '林俊杰',
  '邓紫棋',
  '华语经典',
  '轻音乐',
  '毛不易',
  '粤语经典',
  '薛之谦',
];

/// 平台显示名。
String lxPlatformName(String platform) => switch (platform) {
      'kw' => '酷我',
      'wy' => '网易云',
      'kg' => '酷狗',
      'tx' => 'QQ音乐',
      _ => platform,
    };

/// 全量平台目录（固定顺序；曲库平台与激活脚本解耦，四个平台始终
/// 可选，见 LxRuntime.searchSupportedPlatforms——出链时脚本链自动
/// 跳过不支持当前平台的脚本）。
const List<({String id, String name})> lxPlatforms = [
  (id: 'kw', name: '酷我'),
  (id: 'wy', name: '网易云'),
  (id: 'kg', name: '酷狗'),
  (id: 'tx', name: 'QQ音乐'),
];
