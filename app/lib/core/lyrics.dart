/// LRC 歌词解析（兼容逐字增强格式，保留逐字细度供卡拉 OK 渲染）。

library;

import 'package:characters/characters.dart';

/// 逐字时间轴中的一个字（时间均为绝对毫秒）。
class LyricWord {
  const LyricWord({
    required this.startMs,
    required this.durationMs,
    required this.text,
  });

  final int startMs;
  final int durationMs;
  final String text;

  int get endMs => startMs + durationMs;
}

class LyricLine {
  const LyricLine({
    required this.timeMs,
    required this.text,
    this.durationMs = 0,
    this.words = const [],
  });

  final int timeMs;
  final String text;

  /// 行标签自带的持续时长（`[起始,持续]` 毫秒格式才有）。
  final int durationMs;

  /// 逐字时间轴（无逐字数据时为空，回落整行扫色）。
  final List<LyricWord> words;

  bool get hasWords => words.isNotEmpty;
}

/// 解析 LRC：支持一行多个时间标签与增强逐字时间轴。
///
/// 汽水 SEO/移动端歌词是毫秒逐字变体：行标签 `[起始ms,持续ms]`、
/// 字标签 `<偏移ms,时长ms,音高>`（如 `[1532,4759]<0,288,0>你…`，
/// 字偏移相对行起始），与标准 `[mm:ss.xxx]` / `<mm:ss.xxx>` 同样支持。
List<LyricLine> parseLrc(String raw) {
  final timeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?]');
  final timeTagMs = RegExp(r'\[(\d{1,8}),(\d{1,8})]');
  final wordTag = RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');
  final wordTagMs = RegExp(r'<(\d{1,7}),(\d{1,7})(?:,\d{1,3})?>');
  final lines = <LyricLine>[];
  for (final rawLine in raw.split(RegExp(r'\r?\n'))) {
    final stdTags = timeTag.allMatches(rawLine).toList();
    final msTags = timeTagMs.allMatches(rawLine).toList();
    if (stdTags.isEmpty && msTags.isEmpty) continue;
    // 逐字时间轴（一次解析，两种标签共用；偏移相对行起始）
    final words = _parseWords(rawLine, wordTag, wordTagMs);
    final text = rawLine
        .replaceAll(timeTag, '')
        .replaceAll(timeTagMs, '')
        .replaceAll(wordTag, '')
        .replaceAll(wordTagMs, '')
        .trim();
    if (text.isEmpty) continue;
    for (final tag in stdTags) {
      final minutes = int.parse(tag.group(1)!);
      final seconds = int.parse(tag.group(2)!);
      final fractionRaw = tag.group(3) ?? '0';
      // .9 与 .90 与 .900 都按毫秒归一（按位数补齐）
      final fraction = fractionRaw.length == 1
          ? int.parse(fractionRaw) * 100
          : fractionRaw.length == 2
              ? int.parse(fractionRaw) * 10
              : int.tryParse(fractionRaw.substring(0, 3)) ?? 0;
      final timeMs = minutes * 60000 + seconds * 1000 + fraction;
      lines.add(LyricLine(
        timeMs: timeMs,
        text: text,
        words: _rebaseWords(words, timeMs),
      ));
    }
    for (final tag in msTags) {
      final timeMs = int.parse(tag.group(1)!);
      final durationMs = int.tryParse(tag.group(2) ?? '0') ?? 0;
      lines.add(LyricLine(
        timeMs: timeMs,
        text: text,
        durationMs: durationMs,
        words: _rebaseWords(words, timeMs),
      ));
    }
  }
  lines.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return lines;
}

/// 从原始行提取逐字片段：每个字标签后、下一标签前的文本属于该字。
List<({int offsetMs, int durationMs, String text})> _parseWords(
    String rawLine, RegExp wordTag, RegExp wordTagMs) {
  final matches = [...wordTag.allMatches(rawLine), ...wordTagMs.allMatches(rawLine)]
    ..sort((a, b) => a.start.compareTo(b.start));
  if (matches.isEmpty) return const [];
  final out = <({int offsetMs, int durationMs, String text})>[];
  for (var i = 0; i < matches.length; i++) {
    final match = matches[i];
    final textStart = match.end;
    final textEnd = i + 1 < matches.length ? matches[i + 1].start : rawLine.length;
    var text = rawLine.substring(textStart, textEnd);
    // 混排时截掉残余的另一种字标签（如行首的时间标签已被上一步剥掉）
    text = text
        .replaceAll(wordTag, '')
        .replaceAll(wordTagMs, '')
        .replaceAll(RegExp(r'^[\s,，、]+|[\s,，、]+$'), '');
    if (text.isEmpty) continue;
    out.add((offsetMs: _tagToMs(match), durationMs: _tagDuration(match), text: text));
  }
  return out;
}

/// `<mm:ss.xx>` 或 `<偏移,时长,…>` 标签 → 起始毫秒（按分隔符区分形态）。
int _tagToMs(RegExpMatch match) {
  final inner = match.group(0)!.substring(1, match.group(0)!.length - 1);
  if (inner.contains(':')) {
    final parts = inner.split(':');
    final minutes = int.tryParse(parts[0]) ?? 0;
    final rest = parts[1].split(RegExp(r'[.,]'));
    final seconds = int.tryParse(rest[0]) ?? 0;
    final fractionRaw = rest.length > 1 ? rest[1] : '';
    final fraction = fractionRaw.isEmpty
        ? 0
        : fractionRaw.length == 1
            ? int.parse(fractionRaw) * 100
            : fractionRaw.length == 2
                ? int.parse(fractionRaw) * 10
                : int.tryParse(fractionRaw.substring(0, 3)) ?? 0;
    return minutes * 60000 + seconds * 1000 + fraction;
  }
  return int.tryParse(inner.split(',')[0]) ?? 0;
}

/// 标签里的时长（`<偏移,时长>` 形态第二段；无则回 0）。
int _tagDuration(RegExpMatch match) {
  final inner = match.group(0)!.substring(1, match.group(0)!.length - 1);
  final parts = inner.split(',');
  return parts.length >= 2 ? int.tryParse(parts[1]) ?? 0 : 0;
}

/// 把相对偏移的逐字轴抬到绝对时间（绑定到具体行起始）。
List<LyricWord> _rebaseWords(
    List<({int offsetMs, int durationMs, String text})> words, int lineMs) {
  return words
      .map((word) => LyricWord(
            startMs: lineMs + word.offsetMs,
            durationMs: word.durationMs,
            text: word.text,
          ))
      .toList(growable: false);
}

/// 翻译 LRC 对齐到主歌词行：返回 行下标 → 译文。
///
/// 翻译是标准 `[mm:ss.xx]译文` LRC（无逐字轴）。对齐策略：为每个译文行
/// 找时间差最小的主行（官方翻译时间戳与主歌词同源，通常完全一致；
/// 容差 1.2s 内才认，防止间奏空行错配）。同一主行多条译文取最近一条。
Map<int, String> alignTranslations(
    List<LyricLine> lines, String translationLrc) {
  final translated = parseLrc(translationLrc);
  if (lines.isEmpty || translated.isEmpty) return const {};
  final out = <int, String>{};
  for (final line in translated) {
    var bestIndex = -1;
    var bestDelta = 1200;
    for (var i = 0; i < lines.length; i++) {
      final delta = (lines[i].timeMs - line.timeMs).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        bestIndex = i;
      }
    }
    if (bestIndex >= 0 && line.text.trim().isNotEmpty) {
      out[bestIndex] = line.text.trim();
    }
  }
  return out;
}

/// 当前播放位置对应的歌词下标（无歌词返回 -1）。
int lyricIndexAt(List<LyricLine> lines, int positionMs) {
  if (lines.isEmpty) return -1;
  int low = 0;
  int high = lines.length - 1;
  int result = -1;
  while (low <= high) {
    final mid = (low + high) ~/ 2;
    if (lines[mid].timeMs <= positionMs) {
      result = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return result;
}

/// 行结束时间（逐字轴末字结束 > 行标签持续 > 下一行起始兜底）。
int lyricLineEndMs(List<LyricLine> lines, int index) {
  final line = lines[index];
  if (line.hasWords) {
    final end = line.words.last.endMs;
    if (end > line.timeMs) return end;
  }
  if (line.durationMs > 0) return line.timeMs + line.durationMs;
  return index + 1 < lines.length ? lines[index + 1].timeMs : line.timeMs + 5000;
}

/// 播放位置在行内的扫色进度（0~1，按字数插值——对 CJK 近似等宽视觉准确）。
double lyricProgressAt(List<LyricLine> lines, int index, int positionMs) {
  final line = lines[index];
  final endMs = lyricLineEndMs(lines, index);
  if (positionMs <= line.timeMs) return 0;
  if (positionMs >= endMs) return 1;
  if (!line.hasWords) {
    final span = (endMs - line.timeMs).clamp(1, 1 << 30);
    return ((positionMs - line.timeMs) / span).clamp(0.0, 1.0);
  }
  var total = 0;
  for (final word in line.words) {
    total += word.text.characters.length;
  }
  if (total == 0) return 1;
  var consumed = 0.0;
  for (final word in line.words) {
    final length = word.text.characters.length;
    final wordEnd = word.durationMs > 0 ? word.endMs : word.startMs + 300;
    if (positionMs >= wordEnd) {
      consumed += length;
      continue;
    }
    if (positionMs <= word.startMs) break;
    final span = (wordEnd - word.startMs).clamp(1, 1 << 30);
    consumed += length * (positionMs - word.startMs) / span;
    break;
  }
  return (consumed / total).clamp(0.0, 1.0);
}
