import 'package:edui/models/monitor_account.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('monitor account list round trips without secrets', () {
    final original = [
      MonitorAccount.amdDefault(),
      MonitorAccount.codexDefault(id: 'codex'),
    ];
    final restored = MonitorAccount.decodeList(
      MonitorAccount.encodeList(original),
    );

    expect(restored, hasLength(2));
    expect(restored.first.name, 'AMD Radeon API');
    expect(restored.first.providerType, ProviderType.amdRadeon);
    expect(restored.first.model, isEmpty);
    expect(restored.last.authenticationType, AuthenticationType.manualCookie);
    expect(restored.last.loginUrl, 'https://chatgpt.com/auth/login');
    expect(restored.last.endpointPath, '/backend-api/wham/usage');
    expect(restored.last.metricValueMode, MetricValueMode.usedPercent);
    expect(
      MonitorAccount.encodeList(original),
      isNot(contains('secret-api-key-value')),
    );
    expect(
      MonitorAccount.encodeList(original),
      isNot(contains('session=secret-cookie-value')),
    );
  });

  test('OpenCode Go preset uses the official read-only usage endpoint', () {
    final account = MonitorAccount.openCodeGoDefault(id: 'opencode-go');
    expect(account.providerType, ProviderType.openCodeGo);
    expect(account.baseUrl, 'https://opencode.ai/zen/go/v1');
    expect(account.authenticationType, AuthenticationType.apiKey);
    expect(account.loginUrl, 'https://opencode.ai/zen/go');
  });
}
