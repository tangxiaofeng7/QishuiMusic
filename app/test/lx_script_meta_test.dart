/// lx 脚本头部元信息解析（对齐 lx-music-desktop utils.ts parseScriptInfo）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:qishui_player/core/lx_runtime.dart';

void main() {
  test('解析标准头部注释', () {
    const script = '''
/**
 * @name 六音音源
 * @description 一个聚合音源
 * @version 1.2.3
 * @author pdone
 * @homepage https://example.com/lx
 */
const musicSources = {};
''';
    final meta = parseScriptMeta(script);
    expect(meta.name, '六音音源');
    expect(meta.version, '1.2.3');
    expect(meta.author, 'pdone');
    expect(meta.description, '一个聚合音源');
    expect(meta.homepage, 'https://example.com/lx');
  });

  test('超长字段截断', () {
    final long = List.filled(60, '字').join();
    final meta = parseScriptMeta('/*\n * @name $long\n */\n');
    expect(meta.name.length, 25); // 24 字 + 省略号
    expect(meta.name.endsWith('…'), isTrue);
  });

  test('v 前缀归一（生态脚本常写 @version v1.2.1）', () {
    const script = '/*\n * @version v1.2.1\n * @name 六音音源\n */\n';
    final meta = parseScriptMeta(script);
    expect(meta.version, '1.2.1');
    expect(meta.name, '六音音源');
  });

  test('无头部/无字段给空串', () {
    final none = parseScriptMeta('const a = 1;');
    expect(none.name, isEmpty);
    final noFields = parseScriptMeta('/* 普通注释 */');
    expect(noFields.version, isEmpty);
  });

  test('未知 @key 忽略，已知字段可重复声明取首个之后的最后一个', () {
    const script = '''
/*
 * @unknown whatever
 * @version 2.0
 * @version 3.0
 */
''';
    final meta = parseScriptMeta(script);
    expect(meta.version, '3.0'); // 后声明覆盖（逐行扫描）
  });
}
