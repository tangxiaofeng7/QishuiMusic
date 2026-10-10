import 'package:flutter_test/flutter_test.dart';
import 'package:qishui_player/core/models.dart';

void main() {
  group('ChartEntry.fromBlock', () {
    // 真实回包片段（对齐 libresoda feed.rs 的 DISCOVER_SAMPLE，
    // 抓自 /luna/pc/discover/mix 的 discovery_chart 场景）。
    final block = <String, dynamic>{
      'inner_block_id': '7031074411738515464',
      'title': '热歌榜',
      'resources': [
        {
          'entity': {
            'playlist': {
              'id': '7031074411738515464',
              'title': 'KTV情侣对唱',
              'public_title': 'KTV情侣对唱· 用歌声撒狗粮呀～',
              'desc': '适合去ktv和自己的对象一起唱起来～',
              'count_tracks': 20,
              'type': 3,
              'url_cover': {
                'template_prefix': 'tplv-b829550vbb',
                'uri': 'ies-music/pgc_cover_3656fc2edd76a1f76f5ef87ee9818998',
                'urls': ['https://p3-luna.douyinpic.com/img/'],
              },
            },
          },
          'fallback_type': 'fallback_tcc_downgrade',
        },
      ],
    };

    test('模板形态封面拼出完整地址（对齐 Rust build_image_url）', () {
      final entry = ChartEntry.fromBlock(block)!;
      expect(entry.playlist.cover,
          'https://p3-luna.douyinpic.com/img/ies-music/pgc_cover_3656fc2edd76a1f76f5ef87ee9818998~tplv-b829550vbb-resize:960:960.png');
    });

    test('block 标题优先，曲目数取 count_tracks，展示标题用 public_title 兜底', () {
      final entry = ChartEntry.fromBlock(block)!;
      expect(entry.title, '热歌榜');
      expect(entry.playlist.trackCount, 20);
      expect(entry.playlist.id, '7031074411738515464');

      final noBlockTitle = Map<String, dynamic>.from(block)
        ..remove('title');
      final fallback = ChartEntry.fromBlock(noBlockTitle)!;
      expect(fallback.title, 'KTV情侣对唱· 用歌声撒狗粮呀～');
    });

    test('非模板形态封面 = urls 前缀 + uri', () {
      final plain = <String, dynamic>{
        'resources': [
          {
            'entity': {
              'playlist': {
                'id': '1',
                'title': '榜单',
                'count_tracks': 3,
                'url_cover': {
                  'uri': 'ies-music/pgc_cover_abc',
                  'urls': ['https://p3-luna.douyinpic.com/img/'],
                },
              },
            },
          },
        ],
      };
      final entry = ChartEntry.fromBlock(plain)!;
      expect(entry.playlist.cover,
          'https://p3-luna.douyinpic.com/img/ies-music/pgc_cover_abc');
    });

    test('无歌单实体或无 id 返回 null', () {
      expect(ChartEntry.fromBlock({'resources': []}), isNull);
      expect(
        ChartEntry.fromBlock({
          'resources': [
            {
              'entity': {'playlist': {'title': '无 id'}}
            }
          ],
        }),
        isNull,
      );
    });
  });

  group('Track.fromJson 平台回填', () {
    test('旧版只有 kw_ 前缀 id、无 platform 字段：从 id 推导回填', () {
      // 真机存量数据形态（2026-10-10 用户反馈「切酷我后仍走汽水」的
      // 直接肇因之一）：最近播放/喜欢/会话里的平台曲目丢 platform，
      // 取流分流把平台曲当汽水曲处理。
      final track = Track.fromJson({
        'id': 'kw_198554068',
        'title': '孤勇者',
        'artist': '陈奕迅',
      });
      expect(track.platform, 'kw');
      expect(track.songmid, '198554068');
    });

    test('已有 platform 保持不变；纯汽水 id 不误判', () {
      expect(
        Track.fromJson({
          'id': 'wy_123',
          'title': 'x',
          'platform': 'wy',
        }).platform,
        'wy',
      );
      expect(
        Track.fromJson({
          'id': '7667532994534705202',
          'title': '大天蓬',
        }).platform,
        '',
      );
      expect(
        Track.fromJson({'id': '7667532994534705202', 'title': 'x'}).songmid,
        '7667532994534705202',
      );
    });
  });
}
