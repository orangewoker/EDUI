import 'dart:convert';

import 'package:edui/models/monitor_account.dart';
import 'package:edui/services/quota_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('reads OpenAI organization costs with an admin key', () async {
    final mock = MockClient((request) async {
      expect(request.url.path, '/v1/organization/costs');
      expect(request.url.queryParameters['bucket_width'], '1d');
      expect(request.headers['Authorization'], 'Bearer admin-secret');
      return http.Response(
        jsonEncode({
          'data': [
            {
              'results': [
                {
                  'amount': {'value': 1.25, 'currency': 'usd'},
                },
              ],
            },
            {
              'results': [
                {
                  'amount': {'value': 0.75, 'currency': 'usd'},
                },
              ],
            },
          ],
        }),
        200,
      );
    });

    final snapshot = await QuotaClient(
      client: mock,
    ).refresh(MonitorAccount.openAIDefault(), 'admin-secret');

    expect(snapshot.remaining, 2);
    expect(snapshot.used, 2);
    expect(snapshot.unit, 'USD/30天已用');
  });

  test(
    'calculates remaining OpenAI budget when a limit is configured',
    () async {
      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': [
              {
                'results': [
                  {
                    'amount': {'value': 3.5, 'currency': 'usd'},
                  },
                ],
              },
            ],
          }),
          200,
        ),
      );

      final snapshot = await QuotaClient(client: mock).refresh(
        MonitorAccount.openAIDefault().copyWith(budgetLimit: 10),
        'admin-secret',
      );

      expect(snapshot.remaining, 6.5);
      expect(snapshot.limit, 10);
      expect(snapshot.used, 3.5);
      expect(snapshot.remainingRatio, 0.65);
    },
  );

  test('reads AMD daily USD and RPM quota response headers', () async {
    final mock = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer secret');
      if (request.url.path.endsWith('/v1/usage')) {
        return http.Response('{}', 404);
      }
      if (request.url.path.endsWith('/models')) {
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'auto-model'},
            ],
          }),
          200,
        );
      }
      expect(request.url.path, endsWith('/chat/completions'));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['model'], 'auto-model');
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

    final snapshot = await QuotaClient(client: mock).refresh(
      MonitorAccount.amdDefault().copyWith(model: 'stale-model'),
      'secret',
    );

    expect(snapshot.remaining, 0.75);
    expect(snapshot.limit, 1);
    expect(snapshot.used, 0.25);
    expect(snapshot.unit, 'USD/日');
    expect(snapshot.requestRemaining, 29);
    expect(snapshot.remainingRatio, 0.75);
    expect(snapshot.resetAt, isNotNull);
  });

  test('reads the official Sub2API wallet balance endpoint', () async {
    final mock = MockClient((request) async {
      expect(request.url.path, '/v1/usage');
      expect(request.headers['Authorization'], 'Bearer sub-key');
      return http.Response(
        jsonEncode({
          'mode': 'unrestricted',
          'isValid': true,
          'planName': 'Wallet balance',
          'remaining': 19642.83089036,
          'balance': 19642.83089036,
          'unit': 'USD',
        }),
        200,
      );
    });

    final snapshot = await QuotaClient(client: mock).refresh(
      MonitorAccount.sub2ApiDefault().copyWith(
        baseUrl: 'https://sub2api.example.test',
      ),
      'sub-key',
    );

    expect(snapshot.remaining, 19642.83089036);
    expect(snapshot.unit, 'USD');
    expect(snapshot.message, contains('Sub2API'));
  });

  test(
    'auto-detects Sub2API usage for an existing OpenAI-compatible account',
    () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/v1/usage');
        return http.Response(
          jsonEncode({
            'mode': 'unrestricted',
            'remaining': 42.5,
            'balance': 42.5,
            'unit': 'USD',
          }),
          200,
        );
      });

      final snapshot = await QuotaClient(client: mock).refresh(
        MonitorAccount.amdDefault().copyWith(
          baseUrl: 'https://sub2api.example.test',
        ),
        'sub-key',
      );

      expect(snapshot.remaining, 42.5);
      expect(snapshot.unit, 'USD');
    },
  );

  test('reads Sub2API key quota mode with a base URL ending in v1', () async {
    final resetAt = DateTime.utc(2026, 8, 13, 0);
    final mock = MockClient((request) async {
      expect(request.url.path, '/v1/usage');
      return http.Response(
        jsonEncode({
          'mode': 'quota_limited',
          'remaining': 7,
          'unit': 'USD',
          'quota': {
            'limit': 10,
            'used': 3,
            'remaining': 7,
            'unit': 'USD',
            'reset_at': resetAt.toIso8601String(),
          },
        }),
        200,
      );
    });

    final snapshot = await QuotaClient(client: mock).refresh(
      MonitorAccount.sub2ApiDefault().copyWith(
        baseUrl: 'https://sub2api.example.test/v1',
      ),
      'sub-key',
    );

    expect(snapshot.remaining, 7);
    expect(snapshot.limit, 10);
    expect(snapshot.used, 3);
    expect(snapshot.remainingRatio, 0.7);
    expect(snapshot.resetAt?.toUtc(), resetAt);
  });

  test(
    'falls back to token and request quotas from OpenAI-compatible headers',
    () async {
      final mock = MockClient((request) async {
        if (request.url.path.endsWith('/models')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'gpt-4o-mini'},
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'usage': {'total_tokens': 920},
          }),
          200,
          headers: {
            'X-Ratelimit-Limit-Tokens': '1000000',
            'X-Ratelimit-Remaining-Tokens': '999080',
            'X-Ratelimit-Limit-Requests': '21',
            'X-Ratelimit-Remaining-Requests': '21',
          },
        );
      });

      final snapshot = await QuotaClient(
        client: mock,
      ).refresh(MonitorAccount.amdDefault(), 'secret');

      expect(snapshot.remaining, 999080);
      expect(snapshot.limit, 1000000);
      expect(snapshot.used, 920);
      expect(snapshot.unit, 'Tokens');
      expect(snapshot.requestLimit, 21);
      expect(snapshot.requestRemaining, 21);
    },
  );

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

  test('uses a manually stored cookie for official JSON accounts', () async {
    final mock = MockClient((request) async {
      expect(request.headers['Cookie'], 'session=secret; user=42');
      expect(request.headers.containsKey('Authorization'), isFalse);
      return http.Response(
        jsonEncode({
          'quota': {'remaining': 62, 'limit': 100},
        }),
        200,
      );
    });
    final account = MonitorAccount(
      id: 'official-web',
      name: '官方订阅',
      providerType: ProviderType.customJson,
      baseUrl: 'https://example.test',
      authenticationType: AuthenticationType.manualCookie,
      endpointPath: '/api/quota',
      balanceField: 'quota.remaining',
      limitField: 'quota.limit',
      unit: '%',
    );

    final snapshot = await QuotaClient(
      client: mock,
    ).refresh(account, 'session=secret; user=42');

    expect(snapshot.remaining, 62);
    expect(snapshot.limit, 100);
  });

  test(
    'converts Codex used percent into remaining quota and reset time',
    () async {
      final resetAt = DateTime.utc(2026, 8, 12, 8);
      final mock = MockClient((request) async {
        expect(request.url.path, '/backend-api/wham/usage');
        expect(request.headers['Cookie'], 'session=codex-cookie');
        return http.Response(
          jsonEncode({
            'rate_limit': {
              'primary_window': {
                'used_percent': 28,
                'reset_at': resetAt.millisecondsSinceEpoch ~/ 1000,
              },
            },
          }),
          200,
        );
      });

      final snapshot = await QuotaClient(client: mock).refresh(
        MonitorAccount.codexDefault(id: 'codex'),
        'session=codex-cookie',
      );

      expect(snapshot.remaining, 72);
      expect(snapshot.limit, 100);
      expect(snapshot.used, 28);
      expect(snapshot.resetAt, resetAt.toLocal());
    },
  );
}
