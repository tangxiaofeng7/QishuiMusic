import 'package:flutter_test/flutter_test.dart';
import 'package:qishui_player/core/errors.dart';

void main() {
  group('friendlyError / networkHint', () {
    test('DNS 失败翻译成可操作指引', () {
      const raw = 'Dns Failed: resolve dns name api.qishui.com';
      final text = friendlyError(raw);
      expect(text, contains(raw));
      expect(text, contains('网络不可达'));
      expect(text, contains('系统级安装'));
    });

    test('路由失败同样命中（No route to host）', () {
      expect(networkHint('SocketException: No route to host'), isNotEmpty);
      expect(networkHint('OS Error: lookup address information failed'),
          isNotEmpty);
    });

    test('普通业务错误原样返回，不附加网络指引', () {
      const raw = '读取歌单失败: 未登录';
      expect(friendlyError(raw), raw);
      expect(networkHint(raw), isEmpty);
    });
  });
}
