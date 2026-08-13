import 'dart:convert';

import 'package:edui/services/codex_oauth_credential.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes Sub2API export to the minimal Keychain payload', () {
    final credential = CodexOAuthCredential.parse(
      jsonEncode({
        'type': 'sub2api-data',
        'proxies': [
          {'url': 'https://proxy.invalid'},
        ],
        'accounts': [
          {
            'name': 'space',
            'platform': 'openai',
            'type': 'oauth',
            'concurrency': 3,
            'credentials': {
              'access_token': 'test-access-token',
              'chatgpt_account_id': 'test-account-id',
              'email': 'private@example.invalid',
              'organization_id': 'test-organization-id',
              'plan_type': 'plus',
              'expires_at': '2099-01-01T00:00:00Z',
            },
          },
        ],
      }),
    );

    final stored = credential.encodeForStorage();
    expect(stored, contains('test-access-token'));
    expect(stored, contains('test-account-id'));
    expect(stored, isNot(contains('private@example.invalid')));
    expect(stored, isNot(contains('proxy.invalid')));
    expect(stored, isNot(contains('concurrency')));

    final reparsed = CodexOAuthCredential.parse(stored);
    expect(reparsed.accessToken, 'test-access-token');
    expect(reparsed.accountId, 'test-account-id');
    expect(reparsed.planType, 'plus');
    expect(reparsed.planLabel, 'PLUS');
    expect(reparsed.usesWeeklyPrimary, isTrue);
  });

  test('detects the account plan from access token JWT claims', () {
    String encode(Map<String, dynamic> value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token = [
      encode({'alg': 'none'}),
      encode({
        'exp': DateTime.utc(2099).millisecondsSinceEpoch ~/ 1000,
        'https://api.openai.com/auth': {
          'chatgpt_account_id': 'jwt-account-id',
          'chatgpt_plan_type': 'chatgpt_pro',
        },
      }),
      'signature',
    ].join('.');

    final credential = CodexOAuthCredential.parse(token);
    expect(credential.accountId, 'jwt-account-id');
    expect(credential.planType, 'pro');
    expect(credential.planLabel, 'PRO');
    expect(credential.usesWeeklyPrimary, isTrue);
  });
}
