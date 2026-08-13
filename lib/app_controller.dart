import 'package:flutter/foundation.dart';

import 'models/monitor_account.dart';
import 'models/quota_snapshot.dart';
import 'services/account_store.dart';
import 'services/configuration_backup.dart';
import 'services/quota_client.dart';
import 'services/refresh_throttle.dart';
import 'services/widget_bridge.dart';

class AppController extends ChangeNotifier {
  AppController({
    AccountStore? store,
    QuotaClient? client,
    RefreshThrottle? refreshThrottle,
    WidgetBridge? widgetBridge,
  }) : _store = store ?? AccountStore(),
       _client = client ?? QuotaClient(),
       _refreshThrottle = refreshThrottle ?? RefreshThrottle(),
       _widgetBridge = widgetBridge ?? WidgetBridge();

  final AccountStore _store;
  final QuotaClient _client;
  final RefreshThrottle _refreshThrottle;
  final WidgetBridge _widgetBridge;

  List<MonitorAccount> accounts = [];
  List<QuotaSnapshot> snapshots = [];
  final Set<String> refreshing = {};
  final Map<String, String> errors = {};
  bool loading = true;

  Future<void> initialize() async {
    accounts = await _store.loadAccounts();
    snapshots = await _store.loadSnapshots();
    loading = false;
    notifyListeners();
    await _widgetBridge.sync(accounts, snapshots);
  }

  QuotaSnapshot? snapshotFor(String accountId) {
    for (final snapshot in snapshots) {
      if (snapshot.accountId == accountId) return snapshot;
    }
    return null;
  }

  Future<bool> hasCredential(MonitorAccount account) =>
      _store.hasCredential(account);

  Future<String> createConfigurationBackup() async {
    final credentials = <String, String>{};
    for (final account in accounts) {
      final credential = await _store.readCredential(account);
      if (credential.isNotEmpty) credentials[account.id] = credential;
    }
    return ConfigurationBackup(
      accounts: accounts,
      snapshots: snapshots,
      exportedAt: DateTime.now(),
      credentials: credentials,
    ).encode();
  }

  ConfigurationBackup inspectConfigurationBackup(String raw) =>
      ConfigurationBackup.decode(raw);

  Future<int> restoreConfigurationBackup(
    ConfigurationBackup backup, {
    required bool replace,
  }) async {
    final credentialIds = replace
        ? {
            ...accounts.map((item) => item.id),
            ...backup.accounts.map((item) => item.id),
          }
        : const <String>{};
    if (replace) {
      accounts = backup.accounts;
      snapshots = backup.snapshots;
    } else {
      final accountMap = {for (final item in accounts) item.id: item};
      for (final item in backup.accounts) {
        accountMap[item.id] = item;
      }
      accounts = accountMap.values.toList();

      final snapshotMap = {for (final item in snapshots) item.accountId: item};
      for (final item in backup.snapshots) {
        final current = snapshotMap[item.accountId];
        if (current == null || item.updatedAt.isAfter(current.updatedAt)) {
          snapshotMap[item.accountId] = item;
        }
      }
      snapshots = snapshotMap.values
          .where((item) => accountMap.containsKey(item.accountId))
          .toList();
    }
    errors.clear();
    await Future.wait([
      _store.saveAccounts(accounts),
      _store.saveSnapshots(snapshots),
      for (final accountId in credentialIds)
        _store.deleteAccountSecrets(accountId),
      for (final account in backup.accounts) _refreshThrottle.clear(account.id),
    ]);
    for (final account in backup.accounts) {
      final credential = backup.credentials[account.id];
      if (credential != null && credential.isNotEmpty) {
        await _store.writeCredential(account, credential);
      }
    }
    await _widgetBridge.sync(accounts, snapshots);
    notifyListeners();
    return backup.accounts.length;
  }

  Future<void> saveAccount(MonitorAccount account, String credential) async {
    final index = accounts.indexWhere((item) => item.id == account.id);
    if (index < 0) {
      accounts = [...accounts, account];
    } else {
      final updated = [...accounts];
      updated[index] = account;
      accounts = updated;
    }
    await _store.saveAccounts(accounts);
    await _store.writeCredential(account, credential);
    await _refreshThrottle.clear(account.id);
    errors.remove(account.id);
    notifyListeners();
  }

  Future<void> removeAccount(String accountId) async {
    accounts = accounts.where((item) => item.id != accountId).toList();
    snapshots = snapshots.where((item) => item.accountId != accountId).toList();
    errors.remove(accountId);
    await Future.wait([
      _store.saveAccounts(accounts),
      _store.saveSnapshots(snapshots),
      _store.deleteAccountSecrets(accountId),
      _refreshThrottle.clear(accountId),
    ]);
    await _widgetBridge.sync(accounts, snapshots);
    notifyListeners();
  }

  Future<void> refreshOne(MonitorAccount account) async {
    if (refreshing.contains(account.id)) return;
    refreshing.add(account.id);
    notifyListeners();
    try {
      final decision = await _refreshThrottle.decisionFor(account.id);
      if (!decision.allowed) {
        errors[account.id] =
            '刷新过于频繁，请 ${_formatCooldown(decision.remaining)}后再试。冷却期间不会发送请求。';
        return;
      }

      errors.remove(account.id);
      notifyListeners();
      final credential = await _store.readCredential(account);
      final snapshot = await _client.refresh(account, credential);
      await _refreshThrottle.recordSuccess(account.id);
      snapshots = [
        snapshot,
        ...snapshots.where((item) => item.accountId != account.id),
      ];
      await _store.saveSnapshots(snapshots);
      await _widgetBridge.sync(accounts, snapshots);
    } catch (error) {
      final cooldown = await _refreshThrottle.recordFailure(account.id);
      errors[account.id] = '$error 为保护账户，${_formatCooldown(cooldown)}后可再次刷新。';
    } finally {
      refreshing.remove(account.id);
      notifyListeners();
    }
  }

  Future<void> refreshAll() async {
    for (final account in accounts.where((item) => item.enabled)) {
      await refreshOne(account);
    }
  }

  Future<void> refreshAccounts(Iterable<String> accountIds) async {
    final selected = accountIds.toSet();
    if (selected.isEmpty) {
      await refreshAll();
      return;
    }
    for (final account in accounts.where(
      (item) => item.enabled && selected.contains(item.id),
    )) {
      await refreshOne(account);
    }
  }

  Future<void> refreshStale({
    Duration maxAge = const Duration(minutes: 15),
  }) async {
    final cutoff = DateTime.now().subtract(maxAge);
    final stale = accounts.where((account) {
      if (!account.enabled) return false;
      final snapshot = snapshotFor(account.id);
      return snapshot == null || snapshot.updatedAt.isBefore(cutoff);
    });
    for (final account in stale) {
      await refreshOne(account);
    }
  }

  String _formatCooldown(Duration value) {
    final seconds = value.inSeconds.clamp(1, 24 * 60 * 60);
    if (seconds < 60) return '$seconds 秒';
    final minutes = (seconds / 60).ceil();
    if (minutes < 60) return '$minutes 分钟';
    final hours = (minutes / 60).ceil();
    return '$hours 小时';
  }
}
