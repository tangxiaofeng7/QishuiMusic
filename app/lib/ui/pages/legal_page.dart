import 'package:flutter/material.dart';

/// 服务协议（内置全文，轻量 markdown 渲染：# 标题 / **粗体** / - 列表 / 段落）。
class LegalPage extends StatelessWidget {
  const LegalPage({super.key});

  static const String agreement = '''
# 汽水播放器 服务协议

请在使用前仔细阅读以下条款，继续使用即视为接受。

**最后更新：2026 年 10 月**

## 一、协议说明

本协议是你（以下简称「用户」）与本应用开发者之间就使用「汽水播放器」（以下简称「本应用」）所达成的协议。本应用是一款基于开源引擎构建的第三方音乐播放客户端，面向已持有汽水音乐账号的用户提供移动端播放体验，并支持接入用户自备的其他音源。

请在使用前仔细阅读本协议全部条款。一旦你继续使用本应用，即表示你已完整阅读、充分理解并同意接受本协议的全部内容。

## 二、服务范围

本应用为用户提供本地化的音乐播放能力：浏览、搜索、播放你自己账号有权限访问的内容，以及管理本地缓存。除你主动配置的第三方音源与签名服务外，处理过程均在你的设备本地完成。

本应用不提供任何音乐资源分发、账号体系或付费内容；不内置任何绕过付费或版权限制的能力。一切以本应用名义进行的资源分发、二次发行均与开发者无关。

## 三、用户义务

- 你只能播放自己账号有权限访问的内容；请勿将本应用用于抓取、代理分发或任何商业用途。
- 你接入的第三方音源、脚本与签名服务由你自行准备并自担风险，须遵守其各自的服务条款与当地法律法规。
- 你应自行保管账号凭据。本应用在本地保存会话信息，不会上传到任何开发者控制的服务器。

## 四、免责声明

本应用按「现状」提供，不对可用性、连续性或特定功能作任何担保。因网络波动、上游服务策略变动（如接口风控、限流）导致的功能异常，开发者不承担责任。在法律允许的最大范围内，开发者不对任何间接损失负责。

## 五、开源合规

本应用基于 AGPL-3.0 许可的开源项目构建，完整许可证文本见「设置 → 开源许可证」。你可以在遵守该许可证的前提下获取、修改与再分发本应用的源码。

## 六、协议变更

开发者可能不时修订本协议，修订后的版本随应用更新提供。继续使用更新后的应用即视为接受修订后的协议；不同意时请停止使用并卸载。
''';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('服务协议')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          for (final block in _parseMarkdown(agreement)) block.widget(theme),
        ],
      ),
    );
  }
}

/// 极简 markdown 块（只覆盖协议文本用到的语法）。
sealed class _Block {
  const _Block();
  Widget widget(ThemeData theme);
}

class _Heading extends _Block {
  const _Heading(this.text, {this.large = false});
  final String text;
  final bool large;

  @override
  Widget widget(ThemeData theme) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(
          text,
          style: (large ? theme.textTheme.headlineSmall : theme.textTheme.titleMedium)
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      );
}

class _Paragraph extends _Block {
  const _Paragraph(this.spans);
  final List<InlineSpan> spans;

  @override
  Widget widget(ThemeData theme) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text.rich(
          TextSpan(children: spans),
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
        ),
      );
}

class _Bullet extends _Block {
  const _Bullet(this.spans);
  final List<InlineSpan> spans;

  @override
  Widget widget(ThemeData theme) => Padding(
        padding: const EdgeInsets.only(left: 8, bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('•  '),
            Expanded(
              child: Text.rich(
                TextSpan(children: spans),
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
              ),
            ),
          ],
        ),
      );
}

List<_Block> _parseMarkdown(String source) {
  final blocks = <_Block>[];
  final lines = source.split('\n');
  final buffer = StringBuffer();

  void flushParagraph() {
    final text = buffer.toString().trim();
    buffer.clear();
    if (text.isEmpty) return;
    blocks.add(_Paragraph(_inlineSpans(text)));
  }

  for (final raw in lines) {
    final line = raw.trimRight();
    if (line.startsWith('# ')) {
      flushParagraph();
      blocks.add(_Heading(line.substring(2), large: true));
    } else if (line.startsWith('## ')) {
      flushParagraph();
      blocks.add(_Heading(line.substring(3)));
    } else if (line.startsWith('- ')) {
      flushParagraph();
      blocks.add(_Bullet(_inlineSpans(line.substring(2))));
    } else if (line.trim().isEmpty) {
      flushParagraph();
    } else {
      buffer.writeln(line);
    }
  }
  flushParagraph();
  return blocks;
}

/// `**粗体**` 行内解析（协议正文仅用到这一种行内语法）。
List<InlineSpan> _inlineSpans(String text) {
  final spans = <InlineSpan>[];
  final pattern = RegExp(r'\*\*(.+?)\*\*');
  var start = 0;
  for (final match in pattern.allMatches(text)) {
    if (match.start > start) {
      spans.add(TextSpan(text: text.substring(start, match.start)));
    }
    spans.add(TextSpan(
      text: match.group(1),
      style: const TextStyle(fontWeight: FontWeight.w700),
    ));
    start = match.end;
  }
  if (start < text.length) {
    spans.add(TextSpan(text: text.substring(start)));
  }
  return spans.isEmpty ? [TextSpan(text: text)] : spans;
}
