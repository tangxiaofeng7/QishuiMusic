import 'package:flutter/material.dart';

import '../../brand.dart';

/// 开源许可证：主要组件列表（名称 + 许可徽标 + 仓库），详情展示
/// 许可证全文；「完整第三方许可证」进 Flutter 内置 LicensePage
/// （构建期自动聚合全部依赖的许可文本）。
class LicensesPage extends StatelessWidget {
  const LicensesPage({super.key});

  static const _mitText = '''
MIT License

Copyright (c) 上游项目及其贡献者

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
''';

  static const _bsd3Text = '''
BSD 3-Clause License

Copyright (c) 上游项目及其贡献者

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
''';

  /// Rust 核心依赖普遍采用「MIT OR Apache-2.0」双许可，按任一条款使用
  /// 即合法；详情页按 MIT 全文展示并注明双许可。
  static const _mitOrApacheText =
      '该组件以「MIT OR Apache-2.0」双许可发布，遵循其中任一许可条款'
      '即视为合规；以下为 MIT 许可证全文。\n\n$_mitText';

  @override
  Widget build(BuildContext context) {
    final components = <_LicenseEntry>[
      const _LicenseEntry(
        name: 'ureq（Rust HTTP 客户端）',
        license: 'MIT / Apache-2.0',
        url: 'https://github.com/algesten/ureq',
        text: _mitOrApacheText,
      ),
      const _LicenseEntry(
        name: 'aes / ctr（RustCrypto 解密）',
        license: 'MIT / Apache-2.0',
        url: 'https://github.com/RustCrypto/block-ciphers',
        text: _mitOrApacheText,
      ),
      const _LicenseEntry(
        name: 'serde / serde_json',
        license: 'MIT / Apache-2.0',
        url: 'https://github.com/serde-rs/serde',
        text: _mitOrApacheText,
      ),
      const _LicenseEntry(
        name: 'regex',
        license: 'MIT / Apache-2.0',
        url: 'https://github.com/rust-lang/regex',
        text: _mitOrApacheText,
      ),
      const _LicenseEntry(
        name: 'base64',
        license: 'MIT / Apache-2.0',
        url: 'https://github.com/marshallpierce/rust-base64',
        text: _mitOrApacheText,
      ),
      const _LicenseEntry(
        name: 'Flutter / Dart SDK',
        license: 'BSD-3-Clause',
        url: 'https://github.com/flutter/flutter',
        text: _bsd3Text,
      ),
      const _LicenseEntry(
        name: 'just_audio',
        license: 'MIT',
        url: 'https://github.com/ryanheise/just_audio',
        text: _mitText,
      ),
      const _LicenseEntry(
        name: 'audio_service',
        license: 'MIT',
        url: 'https://github.com/ryanheise/audio_service',
        text: _mitText,
      ),
      const _LicenseEntry(
        name: 'webview_flutter',
        license: 'BSD-3-Clause',
        url: 'https://github.com/flutter/packages',
        text: _bsd3Text,
      ),
      const _LicenseEntry(
        name: 'shared_preferences / path_provider',
        license: 'BSD-3-Clause',
        url: 'https://github.com/flutter/packages',
        text: _bsd3Text,
      ),
      const _LicenseEntry(
        name: 'qr_flutter',
        license: 'BSD-3-Clause',
        url: 'https://github.com/theyakka/qr_flutter',
        text: _bsd3Text,
      ),
      const _LicenseEntry(
        name: 'characters',
        license: 'BSD-3-Clause',
        url: 'https://github.com/dart-lang/core',
        text: _bsd3Text,
      ),
      const _LicenseEntry(
        name: 'ffi',
        license: 'BSD-3-Clause',
        url: 'https://github.com/dart-lang/native',
        text: _bsd3Text,
      ),
    ];
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('开源许可证')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Text(
              '本应用所使用的第三方开源组件（Flutter / Dart 侧与 Rust 核心'
              '侧）遵循其各自的开源许可协议。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          for (final entry in components)
            ListTile(
              title: Text(entry.name),
              subtitle: Text(entry.url, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: _LicenseBadge(entry.license),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _LicenseDetailPage(entry: entry),
                ),
              ),
            ),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.list_alt_outlined),
            title: const Text('完整第三方许可证'),
            subtitle: const Text('全部依赖的许可文本（Flutter 聚合）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLicensePage(
              context: context,
              applicationName: '汽水播放器',
              applicationVersion: kAppVersion,
              applicationIcon: const SizedBox(width: 40, height: 40),
            ),
          ),
        ],
      ),
    );
  }
}

class _LicenseEntry {
  const _LicenseEntry({
    required this.name,
    required this.license,
    required this.url,
    this.text,
  });

  final String name;
  final String license;
  final String url;
  final String? text;
}

class _LicenseBadge extends StatelessWidget {
  const _LicenseBadge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _LicenseDetailPage extends StatefulWidget {
  const _LicenseDetailPage({required this.entry});

  final _LicenseEntry entry;

  @override
  State<_LicenseDetailPage> createState() => _LicenseDetailPageState();
}

class _LicenseDetailPageState extends State<_LicenseDetailPage> {
  String? _text;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _text = widget.entry.text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.entry.name)),
      body: _text == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('许可证加载失败：$_error'),
                    ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: SelectableText(
                _text!,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: ['Menlo', 'Courier New'],
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
    );
  }
}
