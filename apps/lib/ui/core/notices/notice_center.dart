import 'package:flutter/foundation.dart';

import 'app_notice.dart';

class NoticeCenter extends ChangeNotifier {
  final List<AppNotice> _queue = <AppNotice>[];

  AppNotice? get current => _queue.firstOrNull;
  AppNotice? currentFor(NoticePlacement placement) => _queue
      .where((AppNotice notice) => notice.placement == placement)
      .firstOrNull;
  List<AppNotice> get notices => List<AppNotice>.unmodifiable(_queue);

  void publish(AppNotice notice) {
    final String? key = notice.deduplicationKey;
    if (key != null) {
      final int existing = _queue.indexWhere(
        (AppNotice item) => item.deduplicationKey == key,
      );
      if (existing >= 0) {
        _queue[existing] = notice;
        notifyListeners();
        return;
      }
    }
    _queue.add(notice);
    notifyListeners();
  }

  void dismiss(String id) {
    final int before = _queue.length;
    _queue.removeWhere((AppNotice notice) => notice.id == id);
    if (_queue.length != before) notifyListeners();
  }

  void clear() {
    if (_queue.isEmpty) return;
    _queue.clear();
    notifyListeners();
  }
}
