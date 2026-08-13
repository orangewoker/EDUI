import 'dart:convert';

import 'package:edui/services/new_api_credential.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plain New API keys remain backward compatible', () {
    final credential = NewApiCredential.parse('sk-example');
    expect(credential.apiKey, 'sk-example');
    expect(credential.dashboardToken, isEmpty);
    expect(credential.encodeForStorage(), 'sk-example');
  });

  test('merges an API key and dashboard token without losing either', () {
    final merged = NewApiCredential.merge(
      'sk-example',
      dashboardToken: jsonEncode({'access_token': 'dashboard-example'}),
    );
    final credential = NewApiCredential.parse(merged);
    expect(credential.apiKey, 'sk-example');
    expect(credential.dashboardToken, 'dashboard-example');

    final updated = NewApiCredential.parse(
      NewApiCredential.merge(merged, apiKey: 'sk-updated'),
    );
    expect(updated.apiKey, 'sk-updated');
    expect(updated.dashboardToken, 'dashboard-example');
  });
}
