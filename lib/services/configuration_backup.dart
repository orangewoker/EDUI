import 'dart:convert';

import '../models/monitor_account.dart';
import '../models/quota_snapshot.dart';

class ConfigurationBackup {
  const ConfigurationBackup({
    required this.accounts,
    required this.snapshots,
    required this.exportedAt,
  });

  final List<MonitorAccount> accounts;
  final List<QuotaSnapshot> snapshots;
  final DateTime exportedAt;

  String encode() => const JsonEncoder.withIndent('  ').convert({
    'type': 'edui-configuration-backup',
    'version': 1,
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    'containsSecrets': false,
    'accounts': accounts.map((item) => item.toJson()).toList(),
    'snapshots': snapshots.map((item) => item.toJson()).toList(),
  });

  factory ConfigurationBackup.decode(String raw) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const ConfigurationBackupException('备份文件不是有效的 JSON');
    }
    if (decoded is! Map) {
      throw const ConfigurationBackupException('备份文件格式不正确');
    }
    final root = Map<String, dynamic>.from(decoded);
    if (root['type'] != 'edui-configuration-backup') {
      throw const ConfigurationBackupException('这不是 EDUI 配置备份文件');
    }
    final version = int.tryParse('${root['version']}');
    if (version != 1) {
      throw const ConfigurationBackupException('不支持这个备份文件版本');
    }
    final accountValues = root['accounts'];
    if (accountValues is! List) {
      throw const ConfigurationBackupException('备份文件缺少账户配置');
    }
    final accounts = <MonitorAccount>[];
    try {
      for (final item in accountValues.whereType<Map>()) {
        final account = MonitorAccount.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (account.id.trim().isEmpty || account.baseUrl.trim().isEmpty) {
          throw const ConfigurationBackupException('备份中存在无效账户');
        }
        accounts.add(account);
      }
    } on ConfigurationBackupException {
      rethrow;
    } catch (_) {
      throw const ConfigurationBackupException('无法读取备份中的账户配置');
    }
    final accountIds = accounts.map((item) => item.id).toSet();
    final snapshots = <QuotaSnapshot>[];
    final snapshotValues = root['snapshots'];
    if (snapshotValues is List) {
      for (final item in snapshotValues.whereType<Map>()) {
        try {
          final snapshot = QuotaSnapshot.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (accountIds.contains(snapshot.accountId)) snapshots.add(snapshot);
        } catch (_) {
          // A stale or older snapshot must not prevent restoring its account.
        }
      }
    }
    return ConfigurationBackup(
      accounts: accounts,
      snapshots: snapshots,
      exportedAt:
          DateTime.tryParse('${root['exportedAt']}')?.toUtc() ??
          DateTime.now().toUtc(),
    );
  }
}

class ConfigurationBackupException implements Exception {
  const ConfigurationBackupException(this.message);

  final String message;

  @override
  String toString() => message;
}
