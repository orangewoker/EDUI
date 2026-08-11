import 'package:url_launcher/url_launcher.dart';

import '../models/monitor_account.dart';

class LoginLauncher {
  const LoginLauncher();

  Future<bool> open(MonitorAccount account) async {
    final appUri = Uri.tryParse(account.appUrl.trim());
    if (appUri != null && account.appUrl.trim().isNotEmpty) {
      try {
        final openedApp = await launchUrl(
          appUri,
          mode: LaunchMode.externalNonBrowserApplication,
        );
        if (openedApp) return true;
      } catch (_) {
        // Fall through to the provider's web login page.
      }
    }

    final webUri = Uri.tryParse(account.loginUrl.trim());
    if (webUri == null || account.loginUrl.trim().isEmpty) return false;
    return launchUrl(webUri, mode: LaunchMode.externalApplication);
  }
}
