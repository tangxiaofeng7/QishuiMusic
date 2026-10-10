/// 测速结果（会话内存共享：音源列表行与详情页互通）。

library;

import 'package:flutter/foundation.dart';

class SpeedResult {
  const SpeedResult({required this.ms, required this.text, required this.ok});

  final int ms;
  final String text;
  final bool ok;
}

class SpeedStore extends ChangeNotifier {
  final Map<String, SpeedResult> _results = {};

  SpeedResult? of(String sourceId) => _results[sourceId];

  void update(String sourceId, SpeedResult result) {
    _results[sourceId] = result;
    notifyListeners();
  }
}

final speedStore = SpeedStore();
