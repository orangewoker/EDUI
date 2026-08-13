import 'dart:convert';

import 'package:edui/models/monitor_account.dart';
import 'package:edui/models/quota_snapshot.dart';
import 'package:edui/services/configuration_backup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('configuration backup round trips without secrets', () {
    final exportedAt = DateTime.utc(2026, 8, 13, 8);
    final backup = ConfigurationBackup(
      accounts: [MonitorAccount.codexDefault(id: 'codex')],
      snapshots: [
        QuotaSnapshot(
          accountId: 'codex',
          accountName: 'My account',
          remaining: 72,
          limit: 100,
          used: 28,
          unit: '%',
          updatedAt: exportedAt,
          planLabel: 'PLUS',
          quotaWindows: const [
            QuotaWindow(label: '本周额度', remainingPercent: 72),
          ],
        ),
      ],
      exportedAt: exportedAt,
    );

    final raw = backup.encode();
    expect(raw, contains('edui-configuration-backup'));
    expect(raw, contains('"containsSecrets": false'));
    final decoded = jsonDecode(raw);
    final secretKeys = <String>[];
    void findSecretKeys(dynamic value) {
      if (value is Map) {
        for (final entry in value.entries) {
          final key = '${entry.key}'.toLowerCase();
          if (key == 'api_key' ||
              key == 'access_token' ||
              key == 'cookie' ||
              key == 'credential' ||
              key == 'credentials') {
            secretKeys.add(key);
          }
          findSecretKeys(entry.value);
        }
      } else if (value is List) {
        for (final item in value) {
          findSecretKeys(item);
        }
      }
    }

    findSecretKeys(decoded);
    expect(secretKeys, isEmpty);

    final restored = ConfigurationBackup.decode(raw);
    expect(restored.accounts, hasLength(1));
    expect(restored.accounts.single.id, 'codex');
    expect(restored.snapshots, hasLength(1));
    expect(restored.snapshots.single.planLabel, 'PLUS');
    expect(restored.exportedAt, exportedAt);
  });

  test('rejects unrelated and malformed backup files', () {
    expect(
      () => ConfigurationBackup.decode('{not json'),
      throwsA(isA<ConfigurationBackupException>()),
    );
    expect(
      () => ConfigurationBackup.decode('{"type":"something-else"}'),
      throwsA(isA<ConfigurationBackupException>()),
    );
  });

  test('ignores snapshots whose account is not in the backup', () {
    final raw = jsonEncode({
      'type': 'edui-configuration-backup',
      'version': 1,
      'exportedAt': '2026-08-13T08:00:00Z',
      'accounts': [MonitorAccount.codexDefault(id: 'codex').toJson()],
      'snapshots': [
        {
          'accountId': 'not-exported',
          'accountName': 'Unknown',
          'remaining': 10,
          'unit': '%',
          'updatedAt': '2026-08-13T08:00:00Z',
        },
      ],
    });
    final restored = ConfigurationBackup.decode(raw);
    expect(restored.snapshots, isEmpty);
  });
}
