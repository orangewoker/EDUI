import 'dart:convert';

import 'package:home_widget/home_widget.dart';

import '../models/quota_snapshot.dart';

class WidgetBridge {
  static const appGroupId = 'group.com.orangewoker.edui';
  static const widgetKind = 'EDUIWidget';

  Future<void> sync(List<QuotaSnapshot> snapshots) async {
    try {
      await HomeWidget.setAppGroupId(appGroupId);
      final ordered = [...snapshots]
        ..sort((a, b) => a.remaining.compareTo(b.remaining));
      final payload = ordered.take(6).map((item) => item.toJson()).toList();
      await HomeWidget.saveWidgetData<String>(
        'quota_payload',
        jsonEncode(payload),
      );
      await HomeWidget.saveWidgetData<String>(
        'quota_updated_at',
        DateTime.now().toIso8601String(),
      );
      await HomeWidget.updateWidget(iOSName: widgetKind);
    } catch (_) {
      // Widget sharing is only available on a configured iOS target.
    }
  }
}
