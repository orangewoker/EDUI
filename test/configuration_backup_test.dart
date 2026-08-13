import 'dart:convert';

import 'package:edui/models/monitor_account.dart';
import 'package:edui/models/quota_snapshot.dart';
import 'package:edui/services/configuration_backup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('complete configuration backup round trips with credentials', () {
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
      credentials: const {'codex': 'oauth-secret-for-restore'},
    );

    final raw = backup.encode();
    expect(raw, contains('edui-configuration-backup'));
    expect(raw, contains('"containsSecrets": true'));
    expect(raw, contains('oauth-secret-for-restore'));
    final decoded = jsonDecode(raw);
    expect(decoded['version'], 2);

    final restored = ConfigurationBackup.decode(raw);
    expect(restored.accounts, hasLength(1));
    expect(restored.accounts.single.id, 'codex');
    expect(restored.snapshots, hasLength(1));
    expect(restored.snapshots.single.planLabel, 'PLUS');
    expect(restored.exportedAt, exportedAt);
    expect(restored.containsSecrets, isTrue);
    expect(restored.credentials['codex'], 'oauth-secret-for-restore');
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

  test('keeps version one backups compatible without credentials', () {
    final raw = jsonEncode({
      'type': 'edui-configuration-backup',
      'version': 1,
      'exportedAt': '2026-08-13T08:00:00Z',
      'containsSecrets': false,
      'accounts': [MonitorAccount.codexDefault(id: 'legacy').toJson()],
      'snapshots': <Object>[],
    });

    final restored = ConfigurationBackup.decode(raw);
    expect(restored.accounts.single.id, 'legacy');
    expect(restored.credentials, isEmpty);
    expect(restored.containsSecrets, isFalse);
  });

  test('ignores credentials not linked to an exported account', () {
    final raw = jsonEncode({
      'type': 'edui-configuration-backup',
      'version': 2,
      'exportedAt': '2026-08-13T08:00:00Z',
      'containsSecrets': true,
      'accounts': [MonitorAccount.codexDefault(id: 'codex').toJson()],
      'snapshots': <Object>[],
      'credentials': {
        'codex': 'valid-linked-secret',
        'unknown': 'must-not-restore',
      },
    });

    final restored = ConfigurationBackup.decode(raw);
    expect(restored.credentials, {'codex': 'valid-linked-secret'});
  });
}
