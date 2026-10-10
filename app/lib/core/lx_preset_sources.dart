/// 社区推荐音源清单（聚合自 GitHub / Gitee / 博客等开源洛雪音源项目）。
///
/// 2026-10 从 pdone、guoyue2010、Macrohard0001、cdyUuu 等音源仓库的
/// README 与发布页抓取全部音源 URL，去重（App 已随包内置的 pdone/
/// guoyue 28 个脚本除外）并逐个实测后保留以下条目：URL 均返回合法的
/// lx-music 自定义音源脚本（`@name` 头部 + 宿主 API 协议）。
///
/// 第三方源随时可能失效（域名/CDN 波动大），导入失败或测速异常时
/// 属正常现象，可在脚本页删除后重试。
typedef LxPresetSource = ({String name, String url, String note});

const List<LxPresetSource> kPresetLxSources = [
  (
    name: '星海音乐源',
    url: 'https://zrcdy.dpdns.org/lx/xinghai-music-sourcev2.3.15.js',
    note: '聚合 GDAPI/ChKSz 多链回退，支持酷我加密音频；'
        'cdyUuu/lx-music-xinghai-source',
  ),
  (
    name: '聚合音源·净化版',
    url: 'https://cdn.jsdelivr.net/gh/fengs2021/lx-music-merged-source@main/merged-source.js',
    note: '10 个公开源实测精炼聚合，星海+溯音多链回退；'
        'fengs2021/lx-music-merged-source',
  ),
  (
    name: 'HYWmusic 公益版',
    url: 'https://cdn.jsdelivr.net/gh/Macrohard0001/HYWmusic_source@main/HYWmusic_%E5%85%AC%E7%9B%8A%E7%89%88_v1.1.0.js',
    note: 'Macrohard0001 音源合集的公益版；Macrohard0001/HYWmusic_source',
  ),
  (
    name: '落雪云更新音源',
    url: 'https://cdn.jsdelivr.net/gh/moxi5445/lx-music-cloud@main/lx-cloud.js',
    note: '云端清单自动更新，失效源可自愈；moxi5445/lx-music-cloud',
  ),
  (
    name: '墨澜聚合音源（官方最新）',
    url: 'https://github.com/baiji6/molanyinyueyuan/releases/download/%E5%A2%A8%E6%BE%9C%E9%9F%B3%E4%B9%90%E6%BA%90v2.3.4/v2.3.4.js',
    note: '墨澜 v2.3.4 官方发布（内置的 molan 为旧快照）；'
        'baiji6/molanyinyueyuan',
  ),
  (
    name: '独家音源（刘明野新版）',
    url: 'https://cdn.jsdelivr.net/gh/fengyvle/yyt-music-sources@main/liumingye-lx-dujia.js',
    note: 'liumingye lx-dujia 新版（内置 lx/dujia 同族更新）；'
        'fengyvle/yyt-music-sources',
  ),
];
