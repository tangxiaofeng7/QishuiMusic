import 'package:flutter_test/flutter_test.dart';
import 'package:qishui_player/core/lyrics.dart';

void main() {
  group('parseLrc', () {
    test('基本逐行解析并按时间排序', () {
      final lines = parseLrc('[01:02.5]后一句\n[00:01.00]前一句');
      expect(lines.length, 2);
      expect(lines[0].text, '前一句');
      expect(lines[0].timeMs, 1000);
      expect(lines[1].timeMs, 62500);
    });

    test('一行多个时间标签展开为多行', () {
      final lines = parseLrc('[00:10][00:20]副歌');
      expect(lines.length, 2);
      expect(lines.every((line) => line.text == '副歌'), isTrue);
      expect(lines[0].timeMs, 10000);
    });

    test('增强逐字格式剥掉 <mm:ss.xxx> 细度', () {
      final lines = parseLrc('[00:05.20]你<00:05.50>好');
      expect(lines.length, 1);
      expect(lines[0].text, '你好');
      expect(lines[0].timeMs, 5200);
    });

    test('毫秒逐字变体：[起始ms,持续ms] 行标签 + <偏移,时长,音高> 字标签', () {
      // 汽水 SEO 端点实测格式（漫山雪）
      final lines = parseLrc(
          '[1532,4759]<0,288,0>你<288,280,0>看<568,280,0>呐 <848,287,0>山\n'
          '[6292,4239]<0,288,0>我<288,287,0>想');
      expect(lines.length, 2);
      expect(lines[0].timeMs, 1532);
      expect(lines[0].text, '你看呐 山');
      expect(lines[1].timeMs, 6292);
      expect(lines[1].text, '我想');
    });

    test('毫秒变体与标准 [mm:ss] 混排各自解析', () {
      final lines = parseLrc('[1000,500]甲\n[00:05.00]乙');
      expect(lines.length, 2);
      expect(lines[0].timeMs, 1000);
      expect(lines[0].text, '甲');
      expect(lines[1].timeMs, 5000);
      expect(lines[1].text, '乙');
    });

    test('毫秒位数归一（.9 = 900ms）', () {
      expect(parseLrc('[00:01.9]a')[0].timeMs, 1900);
      expect(parseLrc('[00:01.90]a')[0].timeMs, 1900);
      expect(parseLrc('[00:01.900]a')[0].timeMs, 1900);
    });

    test('无时间标签 / 空文本行被忽略', () {
      expect(parseLrc('纯文本无标签'), isEmpty);
      expect(parseLrc('[00:01]   '), isEmpty);
      expect(parseLrc(''), isEmpty);
    });
  });

  group('lyricIndexAt', () {
    final lines = parseLrc('[00:00]零\n[00:10]十\n[00:20]二十');

    test('定位当前行（含边界）', () {
      expect(lyricIndexAt(lines, 0), 0);
      expect(lyricIndexAt(lines, 9999), 0);
      expect(lyricIndexAt(lines, 10000), 1);
      expect(lyricIndexAt(lines, 25000), 2);
    });

    test('第一行之前的进度返回 -1；空歌词返回 -1', () {
      // 首行从 0 开始时 -1 只出现在空表；用非零首行验证前奏区间
      final late = parseLrc('[00:10]十');
      expect(lyricIndexAt(late, 5000), -1);
      expect(lyricIndexAt(const [], 1234), -1);
    });
  });

  group('alignTranslations', () {
    test('时间戳一致的翻译对齐到主行下标', () {
      final main = parseLrc('[9670,2330]The club\n[12030,1650]So the bar');
      final aligned = alignTranslations(
          main, '[00:09.67]夜店不是寻找爱人的最佳场所\n[00:12.03]所以我去了酒吧');
      expect(aligned[0], '夜店不是寻找爱人的最佳场所');
      expect(aligned[1], '所以我去了酒吧');
      expect(aligned.length, 2);
    });

    test('容差外的翻译行被丢弃；空翻译返回空 Map', () {
      final main = parseLrc('[00:10]主歌词');
      expect(alignTranslations(main, '[00:30]偏差 20 秒'), isEmpty);
      expect(alignTranslations(main, ''), isEmpty);
      expect(alignTranslations(const [], '[00:10]x'), isEmpty);
    });
  });
}
