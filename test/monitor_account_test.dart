import 'package:edui/models/monitor_account.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('monitor account list round trips without secrets', () {
    final original = [MonitorAccount.amdDefault()];
    final restored = MonitorAccount.decodeList(
      MonitorAccount.encodeList(original),
    );

    expect(restored, hasLength(1));
    expect(restored.single.name, 'AMD Radeon API');
    expect(restored.single.providerType, ProviderType.amdRadeon);
    expect(restored.single.model, 'Qwen3.6-35B-A3B');
    expect(MonitorAccount.encodeList(original), isNot(contains('apiKey')));
  });
}
