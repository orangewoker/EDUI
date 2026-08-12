import 'dart:convert';

import 'package:edui/models/monitor_account.dart';
import 'package:edui/services/codex_oauth_credential.dart';
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
      if (request.url.path == '/api/status') {
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
    'reads New API account balance without sending a model request',
    () async {
      final requestedPaths = <String>[];
      final mock = MockClient((request) async {
        requestedPaths.add(request.url.path);
        if (request.url.path == '/v1/usage') {
          return http.Response('{}', 404);
        }
        if (request.url.path == '/api/status') {
          expect(request.headers['Authorization'], isNull);
          return http.Response(
            jsonEncode({
              'data': {
                'system_name': 'Example New API',
                'quota_per_unit': 500000,
                'quota_display_type': 'USD',
                'display_in_currency': true,
              },
            }),
            200,
          );
        }
        expect(request.headers['Authorization'], 'Bearer relay-test-key');
        if (request.url.path == '/v1/dashboard/billing/subscription') {
          return http.Response(
            jsonEncode({
              'object': 'billing_subscription',
              'hard_limit_usd': '8.318512',
              'access_until': 0,
            }),
            200,
          );
        }
        if (request.url.path == '/v1/dashboard/billing/usage') {
          return http.Response(
            jsonEncode({'object': 'list', 'total_usage': '286.7416'}),
            200,
          );
        }
        fail('unexpected request: ${request.method} ${request.url}');
      });

      final snapshot = await QuotaClient(client: mock).refresh(
        MonitorAccount.amdDefault().copyWith(
          name: 'New API relay',
          baseUrl: 'https://relay.example.test/v1',
        ),
        'relay-test-key',
      );

      expect(snapshot.limit, closeTo(8.318512, 0.0000001));
      expect(snapshot.used, closeTo(2.867416, 0.0000001));
      expect(snapshot.remaining, closeTo(5.451096, 0.0000001));
      expect(snapshot.unit, 'USD');
      expect(snapshot.message, contains('New API'));
      expect(requestedPaths, isNot(contains('/models')));
      expect(requestedPaths, isNot(contains('/chat/completions')));
    },
  );

  test(
    'falls back to the New API token usage endpoint and converts quota',
    () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/v1/usage') {
          return http.Response('{}', 404);
        }
        if (request.url.path == '/api/status') {
          return http.Response(
            jsonEncode({
              'data': {'quota_per_unit': 500000, 'quota_display_type': 'USD'},
            }),
            200,
          );
        }
        if (request.url.path.contains('/dashboard/billing/')) {
          return http.Response('{}', 404);
        }
        if (request.url.path == '/api/usage/token/') {
          expect(request.url.toString(), endsWith('/api/usage/token/'));
          expect(request.headers['Authorization'], 'Bearer relay-test-key');
          return http.Response(
            jsonEncode({
              'code': true,
              'message': 'ok',
              'data': {
                'object': 'token_usage',
                'total_granted': 5000000,
                'total_used': 1000000,
                'total_available': 4000000,
                'unlimited_quota': false,
                'expires_at': 0,
              },
            }),
            200,
          );
        }
        fail('unexpected request: ${request.method} ${request.url}');
      });

      final snapshot = await QuotaClient(client: mock).refresh(
        MonitorAccount.amdDefault().copyWith(
          baseUrl: 'https://relay.example.test/v1',
        ),
        'relay-test-key',
      );

      expect(snapshot.remaining, 8);
      expect(snapshot.limit, 10);
      expect(snapshot.used, 2);
      expect(snapshot.unit, 'USD');
      expect(snapshot.message, contains('Key'));
    },
  );

  test('also auto-detects New API from the Sub2API preset', () async {
    final mock = MockClient((request) async {
      if (request.url.path == '/v1/usage') return http.Response('{}', 404);
      if (request.url.path == '/api/status') {
        return http.Response(
          jsonEncode({
            'data': {
              'quota_per_unit': 500000,
              'quota_display_type': 'CNY',
              'usd_exchange_rate': 7.2,
            },
          }),
          200,
        );
      }
      if (request.url.path == '/v1/dashboard/billing/subscription') {
        return http.Response(jsonEncode({'hard_limit_usd': 30}), 200);
      }
      if (request.url.path == '/v1/dashboard/billing/usage') {
        return http.Response(jsonEncode({'total_usage': 1250}), 200);
      }
      fail('unexpected request: ${request.method} ${request.url}');
    });

    final snapshot = await QuotaClient(client: mock).refresh(
      MonitorAccount.sub2ApiDefault().copyWith(
        baseUrl: 'https://relay.example.test/v1',
      ),
      'relay-test-key',
    );

    expect(snapshot.remaining, 17.5);
    expect(snapshot.limit, 30);
    expect(snapshot.used, 12.5);
    expect(snapshot.unit, 'CNY');
  });

  test(
    'falls back to token and request quotas from OpenAI-compatible headers',
    () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/status') {
          return http.Response('{}', 404);
        }
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
      expect(snapshot.quotaWindows, hasLength(1));
      expect(snapshot.quotaWindows.single.label, '5 小时额度');
      expect(snapshot.quotaWindows.single.remainingPercent, 72);
    },
  );

  test(
    'extracts access token and account id from Sub2API Codex export JSON',
    () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/backend-api/wham/usage');
        expect(request.headers['Authorization'], 'Bearer oauth-access-token');
        expect(request.headers['ChatGPT-Account-Id'], 'chat-account-123');
        expect(request.headers['User-Agent'], 'codex-cli');
        expect(request.headers['Cookie'], isNull);
        return http.Response(
          jsonEncode({
            'rate_limit': {
              'primary_window': {'used_percent': 12, 'reset_at': 1787314247},
              'secondary_window': {'used_percent': 42, 'reset_at': 1787659200},
            },
          }),
          200,
        );
      });

      final export = jsonEncode({
        'type': 'sub2api-data',
        'accounts': [
          {
            'name': 'space',
            'platform': 'openai',
            'type': 'oauth',
            'credentials': {
              'access_token': 'oauth-access-token',
              'chatgpt_account_id': 'chat-account-123',
            },
          },
        ],
      });
      final snapshot = await QuotaClient(
        client: mock,
      ).refresh(MonitorAccount.codexDefault(id: 'codex'), export);

      expect(snapshot.remaining, 88);
      expect(snapshot.limit, 100);
      expect(snapshot.quotaWindows, hasLength(2));
      expect(snapshot.quotaWindows[0].label, '5 小时额度');
      expect(snapshot.quotaWindows[0].remainingPercent, 88);
      expect(snapshot.quotaWindows[1].label, '本周额度');
      expect(snapshot.quotaWindows[1].remainingPercent, 58);
    },
  );

  test('supports a Codex subscription with only a weekly quota', () async {
    final resetAt = DateTime.utc(2026, 8, 17, 0);
    final mock = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'rate_limit': {
            'secondary_window': {
              'used_percent': 14,
              'reset_at': resetAt.millisecondsSinceEpoch ~/ 1000,
            },
          },
        }),
        200,
      ),
    );

    final snapshot = await QuotaClient(client: mock).refresh(
      MonitorAccount.codexDefault(id: 'weekly-only'),
      'session=weekly-cookie',
    );

    expect(snapshot.remaining, 86);
    expect(snapshot.quotaWindows, hasLength(1));
    expect(snapshot.quotaWindows.single.label, '本周额度');
    expect(snapshot.quotaWindows.single.resetAt, resetAt.toLocal());
  });

  test('keeps raw Cookie credentials compatible with Codex usage', () async {
    final mock = MockClient((request) async {
      expect(request.headers['Cookie'], 'session=legacy-cookie');
      expect(request.headers['Authorization'], isNull);
      return http.Response(
        jsonEncode({
          'rate_limit': {
            'primary_window': {'used_percent': 4},
          },
        }),
        200,
      );
    });
    final snapshot = await QuotaClient(client: mock).refresh(
      MonitorAccount.codexDefault(id: 'codex'),
      'session=legacy-cookie',
    );
    expect(snapshot.remaining, 96);
  });

  test('does not send malformed JSON as a Cookie header', () async {
    final client = QuotaClient(
      client: MockClient((_) async {
        fail('request should not be sent for malformed OAuth JSON');
      }),
    );

    expect(
      () => client.refresh(
        MonitorAccount.codexDefault(id: 'codex'),
        '{not valid json',
      ),
      throwsA(isA<CodexOAuthCredentialException>()),
    );
  });

  test('rejects a Codex OAuth export without ChatGPT account id', () async {
    final client = QuotaClient(
      client: MockClient((_) async {
        fail('request should not be sent without ChatGPT account id');
      }),
    );

    expect(
      () => client.refresh(
        MonitorAccount.codexDefault(id: 'codex'),
        jsonEncode({
          'type': 'sub2api-data',
          'accounts': [
            {
              'platform': 'openai',
              'type': 'oauth',
              'credentials': {'access_token': 'token-without-account'},
            },
          ],
        }),
      ),
      throwsA(isA<CodexOAuthCredentialException>()),
    );
  });

  test('rejects expired or malformed Codex OAuth export JSON', () {
    expect(
      () => CodexOAuthCredential.parse(
        jsonEncode({
          'type': 'sub2api-data',
          'accounts': [
            {
              'platform': 'openai',
              'type': 'oauth',
              'credentials': {
                'access_token': 'expired-token',
                'chatgpt_account_id': 'chat-account-123',
                'expires_at': '2020-01-01T00:00:00Z',
              },
            },
          ],
        }),
      ),
      throwsA(isA<CodexOAuthCredentialException>()),
    );
    expect(
      () => CodexOAuthCredential.parse('{not valid json'),
      throwsA(isA<CodexOAuthCredentialException>()),
    );
  });
}
