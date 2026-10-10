/// 面向用户的错误文案：把底层技术错误翻译成可操作指引。
///
/// 直连模式下的 DNS 解析失败（ureq 的 `Dns Failed: resolve dns name`）
/// 意味着请求根本没到接口——通常是 NECP 封锁（App 未系统级安装）或
/// 设备无网络，而不是接口问题；给用户可执行的下一步而不是裸错误。
library;

String friendlyError(Object error) {
  final text = error.toString();
  final hint = networkHint(text);
  if (hint.isNotEmpty) return '$text$hint';
  return text;
}

String networkHint(String text) {
  if (text.contains('Dns Failed') ||
      text.contains('Failed host lookup') ||
      text.contains('nodename nor servname') ||
      text.contains('lookup address information') ||
      text.contains('No route to host')) {
    return '\n\n网络不可达（DNS 解析失败）：请检查设备联网；可尝试开关一次 Wi-Fi/'
        '飞行模式，或在 Wi-Fi 设置里把 DNS 改为 223.5.5.5 后重试。'
        '若 App 不是系统级安装（/var/jb/Applications），国行 iOS 会封锁出站'
        '网络——请改用系统级安装，或在「设置」配置 HTTP 代理'
        '（http://IP:端口，暂不支持 socks）后重试。';
  }
  return '';
}
