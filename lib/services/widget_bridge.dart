import 'dart:convert';

import 'package:home_widget/home_widget.dart';
import 'package:flutter/services.dart';

import '../models/monitor_account.dart';
import '../models/quota_snapshot.dart';

class WidgetBridge {
  static const appGroupId = 'group.com.orangewoker.edui';
  static const widgetKind = 'EDUIWidget';
  static const _appGroupChannel = MethodChannel('edui/app_group');

  Future<int> sync(
    List<MonitorAccount> accounts,
    List<QuotaSnapshot> snapshots,
  ) async {
    final accountsJson = jsonEncode([
      for (final account in accounts)
        {
          'id': account.id,
          'name': account.name,
          'providerType': account.providerType.name,
        },
    ]);
    final payloadJson = jsonEncode(
      snapshots.map((item) => item.toJson()).toList(),
    );

    try {
      final response = await _appGroupChannel.invokeMapMethod<String, Object?>(
        'sync',
        {'accounts': accountsJson, 'payload': payloadJson},
      );
      return (response?['count'] as num?)?.toInt() ?? 1;
    } catch (_) {
      // Headless isolates and non-iOS platforms do not expose the native
      // bridge. Keep the plugin path as a compatibility fallback.
    }

    try {
      var resolvedGroup = appGroupId;
      try {
        resolvedGroup =
            await _appGroupChannel.invokeMethod<String>('resolve') ??
            appGroupId;
      } catch (_) {
        // A headless iOS background isolate has no Flutter UI channel. The
        // configured base group is still valid for the background callback.
      }
      await HomeWidget.setAppGroupId(resolvedGroup);
      final accountsSaved = await HomeWidget.saveWidgetData<String>(
        'quota_accounts',
        accountsJson,
      );
      final payloadSaved = await HomeWidget.saveWidgetData<String>(
        'quota_payload',
        payloadJson,
      );
      await HomeWidget.updateWidget(iOSName: widgetKind);
      return accountsSaved == true && payloadSaved == true ? 1 : 0;
    } catch (_) {
      // Widget sharing is only available on a configured iOS App Group.
      return 0;
    }
  }
}
