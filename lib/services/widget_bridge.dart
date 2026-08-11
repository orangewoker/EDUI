import 'dart:convert';

import 'package:home_widget/home_widget.dart';

import '../models/monitor_account.dart';
import '../models/quota_snapshot.dart';

class WidgetBridge {
  static const appGroupId = 'group.com.orangewoker.edui';
  static const widgetKind = 'EDUIWidget';

  Future<void> sync(
    List<MonitorAccount> accounts,
    List<QuotaSnapshot> snapshots,
  ) async {
    try {
      await HomeWidget.setAppGroupId(appGroupId);
      await HomeWidget.saveWidgetData<String>(
        'quota_accounts',
        jsonEncode([
          for (final account in accounts)
            {
              'id': account.id,
              'name': account.name,
              'providerType': account.providerType.name,
            },
        ]),
      );
      await HomeWidget.saveWidgetData<String>(
        'quota_payload',
        jsonEncode(snapshots.map((item) => item.toJson()).toList()),
      );
      await HomeWidget.updateWidget(iOSName: widgetKind);
    } catch (_) {
      // Widget sharing is only available on a configured iOS App Group.
    }
  }
}
