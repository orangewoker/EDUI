import 'dart:convert';

import 'package:home_widget/home_widget.dart';
import 'package:flutter/services.dart';

import '../models/monitor_account.dart';
import '../models/quota_snapshot.dart';

class WidgetBridge {
  static const appGroupId = 'group.com.orangewoker.edui';
  static const widgetKind = 'EDUIWidget';
  static const _appGroupChannel = MethodChannel('edui/app_group');

  Future<void> sync(
    List<MonitorAccount> accounts,
    List<QuotaSnapshot> snapshots,
  ) async {
    try {
      final resolvedGroup =
          await _appGroupChannel.invokeMethod<String>('resolve') ?? appGroupId;
      await HomeWidget.setAppGroupId(resolvedGroup);
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
