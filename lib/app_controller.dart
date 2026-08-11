import 'package:flutter/foundation.dart';

import 'models/monitor_account.dart';
import 'models/quota_snapshot.dart';
import 'services/account_store.dart';
import 'services/quota_client.dart';
import 'services/widget_bridge.dart';

class AppController extends ChangeNotifier {
  AppController({
    AccountStore? store,
    QuotaClient? client,
    WidgetBridge? widgetBridge,
  }) : _store = store ?? AccountStore(),
       _client = client ?? QuotaClient(),
       _widgetBridge = widgetBridge ?? WidgetBridge();

  final AccountStore _store;
  final QuotaClient _client;
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
    await _widgetBridge.sync(snapshots);
  }

  QuotaSnapshot? snapshotFor(String accountId) {
    for (final snapshot in snapshots) {
      if (snapshot.accountId == accountId) return snapshot;
    }
    return null;
  }

  Future<bool> hasApiKey(String accountId) => _store.hasApiKey(accountId);

  Future<void> saveAccount(MonitorAccount account, String apiKey) async {
    final index = accounts.indexWhere((item) => item.id == account.id);
    if (index < 0) {
      accounts = [...accounts, account];
    } else {
      final updated = [...accounts];
      updated[index] = account;
      accounts = updated;
    }
    await _store.saveAccounts(accounts);
    await _store.writeApiKey(account.id, apiKey);
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
    ]);
    await _widgetBridge.sync(snapshots);
    notifyListeners();
  }

  Future<void> refreshOne(MonitorAccount account) async {
    if (refreshing.contains(account.id)) return;
    refreshing.add(account.id);
    errors.remove(account.id);
    notifyListeners();
    try {
      final apiKey = await _store.readApiKey(account.id);
      final snapshot = await _client.refresh(account, apiKey);
      snapshots = [
        snapshot,
        ...snapshots.where((item) => item.accountId != account.id),
      ];
      await _store.saveSnapshots(snapshots);
      await _widgetBridge.sync(snapshots);
    } catch (error) {
      errors[account.id] = '$error';
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
}
