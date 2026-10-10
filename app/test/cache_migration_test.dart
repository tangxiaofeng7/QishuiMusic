/// 旧缓存目录（tmp/sodam → Library/Caches/sodam）迁移逻辑测试：
/// 文件搬移、index.json 绝对路径改写、同名冲突不覆盖、幂等。

library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qishui_player/core/store.dart';

void main() {
  late String root;

  setUp(() async {
    // 注意用 .path：Directory 的 toString 是 "Directory: '…'" 不是路径。
    root = (await Directory.systemTemp.createTemp('qishui-migrate-test')).path;
  });

  tearDown(() async {
    final dir = Directory(root);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 造一套旧目录结构：tracks 音频+sidecar+索引、covers 封面。
  void seedLegacyCache() {
    final legacy = '$root/tmp/sodam';
    Directory('$legacy/tracks').createSync(recursive: true);
    Directory('$legacy/covers').createSync(recursive: true);
    File('$legacy/tracks/kw_100-320k.m4a').writeAsBytesSync([1, 2, 3]);
    File('$legacy/tracks/kw_100-320k.quality').writeAsStringSync('320k\t3');
    File('$legacy/covers/abc.img').writeAsBytesSync([4, 5]);
    File('$legacy/tracks/index.json').writeAsStringSync(jsonEncode([
      {
        'id': 'kw_100',
        'title': '旧歌',
        'path': '$legacy/tracks/kw_100-320k.m4a',
        'bytes': 3,
      }
    ]));
  }

  test('音频/封面/索引整套搬到新目录，index.json 路径改写', () async {
    seedLegacyCache();
    final newDir = '$root/Library/Caches/sodam';
    Directory(newDir).createSync(recursive: true);

    await Settings.migrateLegacyCache(root, newDir);

    expect(File('$newDir/tracks/kw_100-320k.m4a').existsSync(), isTrue,
        reason: '音频文件应已搬到新目录');
    expect(File('$newDir/tracks/kw_100-320k.quality').existsSync(), isTrue);
    expect(File('$newDir/covers/abc.img').existsSync(), isTrue);
    expect(Directory('$root/tmp/sodam').existsSync(), isFalse,
        reason: '搬空后旧目录应被清理');

    final index = jsonDecode(
        File('$newDir/tracks/index.json').readAsStringSync()) as List;
    expect(index.single['path'], '$newDir/tracks/kw_100-320k.m4a',
        reason: '索引绝对路径应改写到新目录');
  });

  test('新目录已有同名文件时不覆盖（降级又升级场景）', () async {
    seedLegacyCache();
    final newDir = '$root/Library/Caches/sodam';
    Directory('$newDir/tracks').createSync(recursive: true);
    File('$newDir/tracks/kw_100-320k.m4a').writeAsBytesSync([9]);

    await Settings.migrateLegacyCache(root, newDir);

    expect(File('$newDir/tracks/kw_100-320k.m4a').lengthSync(), 1,
        reason: '新目录已有内容应保留，不被旧文件覆盖');
  });

  test('旧目录不存在时为空操作；同路径（桌面回落）直接跳过', () async {
    // 旧目录不存在
    await Settings.migrateLegacyCache(root, '$root/Library/Caches/sodam');
    expect(Directory('$root/Library/Caches/sodam').existsSync(), isFalse);

    // 桌面/回落形态：新目录就是旧目录，不能把自己搬空
    final tmpSodam = '$root/tmp/sodam';
    Directory(tmpSodam).createSync(recursive: true);
    File('$tmpSodam/x').writeAsStringSync('keep');
    await Settings.migrateLegacyCache(root, tmpSodam);
    expect(File('$tmpSodam/x').existsSync(), isTrue);
  });

  test('重复执行幂等（迁移门闩外再调一次不炸不丢）', () async {
    seedLegacyCache();
    final newDir = '$root/Library/Caches/sodam';
    Directory(newDir).createSync(recursive: true);

    await Settings.migrateLegacyCache(root, newDir);
    await Settings.migrateLegacyCache(root, newDir);

    expect(File('$newDir/tracks/kw_100-320k.m4a').existsSync(), isTrue);
    final index = jsonDecode(
        File('$newDir/tracks/index.json').readAsStringSync()) as List;
    expect(index.single['path'], '$newDir/tracks/kw_100-320k.m4a');
  });
}
