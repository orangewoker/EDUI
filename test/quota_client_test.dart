import 'dart:convert';

import 'package:edui/models/monitor_account.dart';
import 'package:edui/services/quota_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('reads AMD daily USD and RPM quota response headers', () async {
    final mock = MockClient((request) async {
      expect(request.url.path, endsWith('/chat/completions'));
      expect(request.headers['Authorization'], 'Bearer secret');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['max_tokens'], 1);
      return http.Response(
        jsonEncode({
          'usage': {'cost': 0.00001},
        }),
        200,
        headers: {
          'x-ratelimit-limit-user-daily-usd': '1',
          'x-ratelimit-remaining-user-daily-usd': '0.75',
          'x-ratelimit-used-user-daily-usd': '0.25',
          'x-ratelimit-limit-user-rpm': '30',
          'x-ratelimit-remaining-user-rpm': '29',
          'x-ratelimit-reset-user-daily-usd': '1786550400',
        },
      );
    });

    final snapshot = await QuotaClient(
      client: mock,
    ).refresh(MonitorAccount.amdDefault(), 'secret');

    expect(snapshot.remaining, 0.75);
    expect(snapshot.limit, 1);
    expect(snapshot.used, 0.25);
    expect(snapshot.unit, 'USD/日');
    expect(snapshot.requestRemaining, 29);
    expect(snapshot.remainingRatio, 0.75);
    expect(snapshot.resetAt, isNotNull);
  });

  test('reads DeepSeek total balance', () async {
    final mock = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'is_available': true,
          'balance_infos': [
            {
              'currency': 'CNY',
              'total_balance': '110.00',
              'granted_balance': '10.00',
              'topped_up_balance': '100.00',
            },
          ],
        }),
        200,
      ),
    );
    final account = MonitorAccount(
      id: 'deepseek',
      name: 'DeepSeek',
      providerType: ProviderType.deepSeek,
      baseUrl: 'https://api.deepseek.com',
    );

    final snapshot = await QuotaClient(client: mock).refresh(account, 'secret');

    expect(snapshot.remaining, 110);
    expect(snapshot.unit, 'CNY');
    expect(snapshot.message, '余额可用');
  });

  test('reads dotted custom JSON paths', () async {
    final mock = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'data': {'quota': 24, 'limit': 100},
        }),
        200,
      ),
    );
    final account = MonitorAccount(
      id: 'custom',
      name: 'Custom',
      providerType: ProviderType.customJson,
      baseUrl: 'https://example.test/v1',
      endpointPath: '/me',
      balanceField: 'data.quota',
      limitField: 'data.limit',
    );

    final snapshot = await QuotaClient(client: mock).refresh(account, 'secret');

    expect(snapshot.remaining, 24);
    expect(snapshot.limit, 100);
    expect(snapshot.used, 76);
  });
}
