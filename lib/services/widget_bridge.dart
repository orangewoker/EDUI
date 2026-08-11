import 'package:home_widget/home_widget.dart';

import '../models/quota_snapshot.dart';

class WidgetBridge {
  static const widgetKind = 'EDUIWidget';

  Future<void> sync(List<QuotaSnapshot> snapshots) async {
    try {
      await HomeWidget.updateWidget(iOSName: widgetKind);
    } catch (_) {
      // WidgetKit refresh is only available on iOS.
    }
  }
}
