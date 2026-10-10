/// 更新日志：版本更新后首次启动弹一次变更说明；设置页可随时查看全部。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../brand.dart';

class ChangelogEntry {
  const ChangelogEntry(this.version, this.date, this.items);

  final String version;
  final String date;
  final List<String> items;
}

/// 版本变更记录（新版本在前；发版时在此补一段，CI 会注入同版本号）。
const List<ChangelogEntry> kChangelog = [
  ChangelogEntry('1.0.0', '2026-10-10', [
    '首个正式版本：Flutter + Rust 单一代码库，iOS / Android 双平台',
    '汽水FM · 无限电台：风格电台一键开播，队列余量不足自动续歌（不重样）',
    '发现页：排行榜 / 歌单广场 / 推荐歌单，内容发现一页打尽',
    '沉浸式播放页：封面取色渐变、上下滑切歌、逐字卡拉 OK 歌词（翻译可开关）、'
        '相似歌曲、倍速 / 睡眠定时 / ±15 秒快退快进 / 音质切换',
    '播放页 DIY 美化：壁纸背景、黑胶唱片封面、进度条 5 款样式、'
        '歌词样式（字号 / 配色 / 发光 / 3D 倾斜）、主题色板、快捷按钮拖动排序',
    '歌单全家桶：收藏 / 新建 / 重命名 / 拖拽排序回写服务端、'
        '导入网易云 / QQ 音乐歌单、「下一首播放」一键插队',
    '我的：音乐墙、我喜欢的音乐、听歌排行（一周 / 全部）、最近播放、关注的艺人',
    '多音源取流：汽水账号 / 签名链（VIP 无损）/ 内置洛雪脚本（27+ 免费源）',
    '扫码 / Cookie 登录，零外部依赖',
    '设置备份与恢复、缓存管理、GitHub 在线检查更新（TrollStore 一键升级）',
  ]),
];

Future<void> maybeShowChangelog(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getString('lastChangelogVersion') == kAppVersion) return;
  await prefs.setString('lastChangelogVersion', kAppVersion);
  // 本地 dev 构建或无记录版本不弹（避免开发期打扰）
  final entry = kChangelog
      .where((entry) => entry.version == kAppVersion)
      .firstOrNull;
  if (entry == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => _ChangelogDialog(entries: [entry]),
  );
}

/// 设置页查看全部版本记录。
void showChangelogList(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => const _ChangelogDialog(all: true),
  );
}

class _ChangelogDialog extends StatelessWidget {
  const _ChangelogDialog({this.entries, this.all = false});

  final List<ChangelogEntry>? entries;
  final bool all;

  @override
  Widget build(BuildContext context) {
    final list = entries ?? kChangelog;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(all ? '更新日志' : '已更新到 v${list.first.version}'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in list) ...[
                Row(
                  children: [
                    Text('v${entry.version}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        )),
                    const SizedBox(width: 8),
                    Text(entry.date,
                        style:
                            TextStyle(fontSize: 12, color: scheme.outline)),
                  ],
                ),
                const SizedBox(height: 6),
                for (final item in entry.items)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('· ', style: TextStyle(color: scheme.primary)),
                        Expanded(child: Text(item)),
                      ],
                    ),
                  ),
                if (entry != list.last) const Divider(height: 20),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }
}
